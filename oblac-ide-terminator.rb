#!/usr/bin/env ruby

require 'logger'
require 'redis'
require 'docker'

$logger = Logger.new(STDERR)
$logger.level = Logger::INFO

redis_host = ENV['REDIS_PORT_6379_TCP_ADDR'] || 'localhost'
redis_port = 6379

$redis = Redis.new(timeout: 0, host: redis_host, port: redis_port)
$redis_subscriber = Redis.new(timeout: 0, host: redis_host, port: redis_port)

SESSION_TO_CONTAINER_KEY_PREFIX = "s2c"

# Removes Docker container by session id and clears Redis keys related to session id.
#
# Four Redis keys are associated with running Docker containers:
# - session_id stores encrypted session data
# - s2c:session_id:port stores mapping session id to container port, e.g. s2c:80c7 => 32887
# - s2c:session_id:cid stores Docker container id, e.g. s2c:80c7:cid => f25d
# - s2c:session_id:shadow stores empty value that is going to expire
#
# Once the s2c:session_id:shadow expires, this script gets a notification. It uses the s2c:session_id:shadow key
# to extract session_id and then it removes container and related Redis keys.
#
# This script effectively stops and removes Docker containers that have been running,
# but not used over a long period of time (determined by TTL of s2c:session_id:shadow key).
#
# Whenever a request is made to Nginx reverse proxy s2c:session_id:shadow key TTL is refreshed and so
# the containers that are being used are not stopped and removed.
#
def remove_container_by_session_id(session_id)
  $logger.info("Remove container by session id: #{session_id}")
  cid = $redis.get("#{SESSION_TO_CONTAINER_KEY_PREFIX}:#{session_id}:cid") # get Docker container id
  if cid
    # stop and remove container
    container = Docker::Container.get(cid)
    if container
      container.stop
      container.remove
      $logger.info("Container is stopped and removed: #{cid}")
    else
      $logger.warn("No container found for cid: #{cid}")
    end
  else
    $logger.warn("No cid found for session: #{session_id}")
  end

  # in any case remove keys related to session_id
  # sc2:session_id:shadow is already removed due to expiry
  port_session_key = "#{SESSION_TO_CONTAINER_KEY_PREFIX}:#{session_id}:port"
  cid_session_key = "#{SESSION_TO_CONTAINER_KEY_PREFIX}:#{session_id}:cid"
  $redis.del(port_session_key, cid_session_key)
  $logger.info("Redis keys are removed: #{port_session_key} and #{cid_session_key}")
end

def build_redis
  Redis.new(host: ENV['REDIS_PORT_6379_TCP_ADDR'], port: 6379)
end

# Subscribe to Redis Key-event notification expired. See: http://redis.io/topics/notifications.
# Enable notifications using the notify-keyspace-events of redis.conf or via the CONFIG SET.
$redis_subscriber.subscribe("__keyevent@0__:expired") do |on|
  on.message do |channel, msg|
    if msg.match(/#{SESSION_TO_CONTAINER_KEY_PREFIX}:.*:shadow/)
      namespace, session_id, shadow = msg.split(':')
      remove_container_by_session_id(session_id)
    end
  end
end
