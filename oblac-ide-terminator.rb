require 'rubygems'
require 'redis'
require 'json'

$redis = Redis.new(:timeout => 0)

puts "ok"