require 'json'
require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

Dir.glob('./lib/*.rb') { |f| require f }

SEQUENCER = Sequencer.new(SequencerConfig.new('config.json').config)

loop do
  SEQUENCER.tick
  sleep(0.01)
end
