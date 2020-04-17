require 'json'

class SequencerConfig
  attr_reader :config

  def initialize(config_path)
    @config =
      if File.exists?(config_path)
        JSON.parse(File.read(config_path), symbolize_names: true)
      else
        setup.tap do |new_config|
          File.write(config_path, new_config.to_json)
        end
      end
  end

  private

  # TODO: This is duplicated in SequencerConfig
  def get_notes(data)
    data
      .flat_map { |d| d[:data] }
      .each_slice(3)
      .select { |d, _, _| d >= 0x80 && d <= 0x9F }
      .map do |type, note, velocity|
        side = (type < 0x90 || velocity.zero?) ? :off : :on
        channel = type % 16
        [side, channel, note, velocity]
      end
  end

  def get_note_ons(data)
    get_notes(data)
      .select { |side, _, _, _| side == :on }
      .map { |side, channel, note, velocity| [channel, note, velocity] }
  end

  def await_incoming_note(prompt)
    print "#{prompt}…"
    loop do
      input, (channel, note) =
        UniMIDI::Input
        .map { |i| [i, get_note_ons(i.gets).first] }
        .find { |_, data| data }
      if input
        result = [input.name, channel, note]
        puts result.inspect
        return result
      end
      sleep(0.01)
    end
  end

  def setup
    config = {
      parts: [],
      patterns: [],
      steps: [],
      mutes: [],
      voice: nil,
      play: nil,
      record: nil,
      clear: nil,
    }

    # TODO: Make all these constants part of the config, and configurable
    Sequencer::PARTS.times do |part|
      config[:parts].push \
        await_incoming_note("Press Part #{part + 1} of #{Sequencer::PARTS}")
    end

    Sequencer::PARTS.times do |part|
      config[:mutes].push \
        await_incoming_note("Press Mute #{part + 1} of #{Sequencer::PARTS}")
    end

    Sequencer::PARTS.times do |part|
      Sequencer::PATTERNS.times do |pattern|
        config[:patterns].push \
          await_incoming_note("Press Part #{part + 1}, Pattern #{pattern + 1} of #{Sequencer::PATTERNS}")
      end
    end

    Sequencer::STEPS.times do |step|
      config[:steps].push \
        await_incoming_note("Press Step #{step + 1} of #{Sequencer::STEPS}")
    end

    %i(voice clear record play).each do |key|
      config[key] =
        await_incoming_note \
          "Press #{key.to_s.gsub(/_/, ' ').gsub(/\b(.)/, '\L\1')}"
    end

    config[:performance] =
      await_incoming_note \
        'Finally, press any note on your performance controller'

    config
  end
end
