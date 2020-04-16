# TODO
# - Pattern lengths seem to be buggy
# - Should record turn off if play stops?
# - Swing
# - Pattern switching
# - Pattern chains
# - Step length
# - Default note/velocity for each track
# - Set step when selected on sequence
# - Voiced mode
# - Write tests

require 'set'
require 'json'
require 'unimidi'

class Sequencer
  PARTS = 8
  PATTERNS = 4
  STEPS = 32
  NOTES = 127

  # How many seconds do we need to hold a toggle before it switches from
  # latch mode to hold mode?
  HOLD_DURATION = 0.3

  COLORS = {
    red_light: 13,
    red_dark: 19,
    orange_light: 25,
    orange_dark: 31,
    yellow_light: 37,
    yellow_dark: 43,
    lime_light: 49,
    lime_dark: 55,
    forest_light: 61,
    forest_dark: 67,
    teal_light: 73,
    teal_dark: 79,
    blue_light: 85,
    blue_dark: 91,
    purple_light: 97,
    purple_dark: 103,
    magenta_light: 109,
    magenta_dark: 115,
    white: 121,
    black: 0
  }

  def initialize(config_path)
    # For which part should we show steps and accept MIDI input?
    @focused_part = 0

    @previous_focused_part = 0

    # Parts where this is `true` do not send MIDI data
    @mutes = PARTS.times.map { false }

    @patterns =
      PARTS.times.map do
        PATTERNS.times.map do
          STEPS.times.map do
            NOTES.times.map do
              # The velocity of this pitch on this step in this pattern for this
              # part. A velocity of -1 is a hold from the previous step.
              0
            end
          end
        end
      end

    @pattern_lengths =
      (PARTS * PATTERNS).times.map { STEPS }

    @sequences =
      PARTS.times.map do
        # Which patterns are in this sequence, and on what beat was this sequence
        # started?
        [[0], 0]
      end

    @draft_sequences =
      PARTS.times.map do
        []
      end

    # Sequences to be updates on the next bar
    @queued_sequences =
      PARTS.times.map do
        []
      end

    # When did we start playing, in milliseconds?
    @started_at = Time.now.to_f

    # We'll store this every tick for just for consistency
    @now = Time.now.to_f

    # TODO: Support MIDI clock input for BPM
    @bpm = 120

    # The current beat, starting from 0 at @started_at and incrementing every
    # 1/(@bpm / 60) seconds
    @beat = 0

    @beat_started_at = 0

    @written_steps = STEPS.times.map { false }

    # To determine whether this is the first tick of a new beat
    @last_beat = 0

    # An array of presses identified by type, index, and when it was pressed
    @presses = {}

    @states = {
      mute: false,
      voice: false,
      play: false,
      record: false,
      clear_notes: false,
      clear_automation: false
    }

    @colors = {}

    @config =
      if File.exists?(config_path)
        JSON.parse(File.read(config_path), symbolize_names: true)
      else
        setup.tap do |new_config|
          File.write(config_path, new_config.to_json)
        end
      end

    @note_output = UniMIDI::Output.first
  end

  def tick
    @now = Time.now.to_f
    if @states[:play]
      @beat = (((@now - @started_at) * (@bpm / 60.0)) * 4).floor
    end
    handle_input
    unless @beat == @last_beat
      @beat_started_at = @now
      handle_new_beat
    end
    update_visuals
    @last_beat = @beat
  end

  private

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
      mute: nil,
      voice: nil,
      play: nil,
      record: nil,
      clear_notes: nil,
      clear_automation: nil
    }

    PARTS.times do |part|
      config[:parts].push \
        await_incoming_note("Press Part #{part + 1} of #{PARTS}")
    end

    PARTS.times do |part|
      PATTERNS.times do |pattern|
        config[:patterns].push \
          await_incoming_note("Press Part #{part + 1}, Pattern #{pattern + 1} of #{PATTERNS}")
      end
    end

    STEPS.times do |step|
      config[:steps].push \
        await_incoming_note("Press Step #{step + 1} of #{STEPS}")
    end

    %i(mute voice play record clear_notes clear_automation).each do |key|
      config[key] =
        await_incoming_note \
          "Press #{key.to_s.gsub(/_/, ' ').gsub(/\b(.)/, '\L\1')}"
    end

    config[:performance] =
      await_incoming_note \
        'Finally, press any note on your performance controller'

    config
  end

  def translate_raw_input(device, notes)
    notes.map do |side, channel, note, velocity|
      value = nil

      @config.each do |label, choices|
        break if value
        options = choices.size > 3 ? choices : [choices]
        options.each_with_index do |(device_name, option_channel, option_note), index|
          next unless device.name == device_name && channel == option_channel && note == option_note
          value = [side, label, index, velocity]
          break
        end
      end
    end.compact
  end

  def identify_note(device, channel, note)
    if device.name == @config[:performance][0]
      return [:performance, note]
    end

    @config.each do |label, choices|
      options = choices.size > 3 ? choices : [choices]
      options.each_with_index do |(device_name, option_channel, option_note), index|
        if device.name == device_name && channel == option_channel && note == option_note
          return [label, index]
        end
      end
    end

    nil
  end

  def input_devices
    @input_devices ||= devices(UniMIDI::Input)
  end

  def output_devices
    @output_devices ||= devices(UniMIDI::Output)
  end

  def devices(klass)
    @config
      .values
      .flatten
      .select { |v| v.is_a?(String) }
      .uniq
      .each_with_object({}) do |name, hash|
        hash[name] = klass.select { |i| i.name == name }.last
      end
  end

  def handle_note_on(label, index, velocity)
    case label
    when :performance
      @note_output.puts(0x90 + @focused_part, index, velocity)

      if @states[:record]
        pattern, step = current_step(@focused_part)
        @patterns[@focused_part][pattern][step][index] = velocity
      elsif (pressed_step = @presses.find { |(label, _), _| label == :steps })
        pattern, _ = current_step(@focused_part)
        step = pressed_step[0][1]
        @patterns[@focused_part][pattern][step][index] = velocity
        @written_steps[step] = true
      end
    when :parts
      if @states[:mute]
        @mutes[index] = !@mutes[index]
      else
        # TODO: If any performance notes are pressed, queue part focus change
        # but don't change it yet
        @previous_focused_part = @focused_part
        @focused_part = index
      end
    when :patterns
      part = (index / PATTERNS.to_f).floor
      pattern = index % PATTERNS
      # TODO: Set @draft_sequences[part] to current min and max pattern presses
      # for part
    when :steps
      @written_steps[index] = false
      # TODO: If a previous step is also pressed, set gate length for that step
      # to the distance to this step
      pattern, _ = current_step(@focused_part)
      pattern_index = @focused_part * PATTERNS + pattern
      if @presses[[:patterns, pattern_index]]
        @pattern_lengths[pattern_index] = index + 1
      end
    when :mute, :voice, :play, :record, :clear_notes, :clear_automation
      @states[label] = !@states[label]
      handle_play if label == :play
    end

    @presses[[label, index]] = [velocity, @now]
  end

  # This should be called only when @states[:play] changes
  def handle_play
    if @states[:play]
      @started_at = @now
      @beat = (((@now - @started_at) * (@bpm / 60.0)) * 4).floor
    else
      PARTS.times.each do |part|
        NOTES.times.each do |note|
          @note_output.puts(0x80 + part, note, 0)
        end
      end
    end
  end

  def handle_note_off(label, index)
    held = @now - @presses[[label, index]][1] >= HOLD_DURATION

    case label
    when :performance
      @note_output.puts(0x80 + @focused_part, index, 0)
      # TODO: If no more performance notes are pressed, change part focus to
      # queued part focus
    when :parts
      if held
        # TODO: Support queued focus
        @focused_part = @previous_focused_part
      end
    when :patterns
      # Are any other patterns still pressed for this part?
      part = (index / PATTERNS.to_f).floor
      if @presses.none? { |(p_label, p_index), _| p_label == label && p_index != index && (p_index / PATTERNS.to_f).floor == part }
        @queued_sequences[part] = @draft_sequences[part]
        @draft_sequences[part] = []
      end
    when :steps
      unless @written_steps[index] || @presses.any? { |(p_label, p_index), _| p_label == label && p_index != index  }
        pattern, _ = current_step(@focused_part)
        @patterns[@focused_part][pattern][index] = NOTES.times.map { 0 }
      end
    when :mute, :voice, :play, :record, :clear_notes, :clear_automation
      if held
        @states[label] = !@states[label]
        handle_play if label == :play
      end
    end

    @presses.delete([label, index])
  end

  def handle_input
    input_devices.each do |_, device|
      get_notes(device.gets).each do |side, channel, note, velocity|
        label, index = identify_note(device, channel, note)

        if side == :on
          handle_note_on(label, index, velocity)
        else
          handle_note_off(label, index)
        end
      end
    end
  end

  def handle_new_beat
    pattern, step = current_step(@focused_part)

    if @states[:clear_notes]
      @patterns[@focused_part][pattern][step] = NOTES.times.map { 0 }
    end

    if @states[:record]
      @presses
        .select { |(label, _), _| label == :performance }
        .each do |(label, note), (velocity, pressed_at)|
          hold =
            @beat_started_at > pressed_at &&
            step > 0 &&
            [velocity, -1].include?(@patterns[@focused_part][pattern][step - 1][note])

          @patterns[@focused_part][pattern][step][note] = hold ? -1 : velocity
        end
    end

    if @states[:play]
      notes = []
      PARTS.times.each do |part|
        pattern, step = current_step(part)
        @patterns[part][pattern][step].each_with_index do |velocity, note|
          case velocity
          when -1
            # This is a hold; do nothing
          when 0
            last_step = step.zero? ? @pattern_lengths[pattern] - 1 : step - 1
            unless @patterns[part][pattern][last_step][note].zero?
              notes += [0x80 + part, note, 0]
            end
          else
            notes += [0x90 + part, note, velocity]
          end
        end
      end
      @note_output.puts(notes)
    end
  end

  def current_step(part)
    # TODO: Return current pattern and step for part
    current_pattern = 0
    current_step = @beat % @pattern_lengths[0]
    [current_pattern, current_step]
  end

  def set_color(label, index, color)
    return if @colors[[label, index]] == color

    @colors[[label, index]] = color

    device_name, channel, note =
      if @config[label].size < 4
        @config[label]
      else
        @config[label][index]
      end

    output_devices[device_name].puts(0x90 + channel, note, color)
  end

  def update_visuals
    @config.each do |label, index|
      case label
      when :parts
        PARTS.times.each do |part|
          active = @states[:mute] ? @mutes[part] : part == @focused_part
          set_color(label, part, active ? 127 : 0)
        end
      when :patterns
        PARTS.times.each do |part|
          active_pattern = current_step(part).first
          PATTERNS.times.each do |pattern|
            color =
              if active_pattern == pattern
                3
              elsif @sequences[part].first.include?(pattern)
                1
              else
                0
              end
            set_color(label, part * PATTERNS + pattern, color)
          end
        end
      when :steps
        pattern, current_step = current_step(@focused_part)
        steps = @patterns[@focused_part][pattern]
        STEPS.times.each do |step|
          color =
            if @states[:play] && step == current_step
              3
            elsif !steps[step].all?(&:zero?)
              1
            else
              0
            end
          set_color(label, step, color)
        end
      when :mute, :voice, :play, :record, :clear_notes, :clear_automation
        set_color(label, 0, @states[label] ? 127 : 0)
      end
    end
  end
end

SEQUENCER = Sequencer.new('config.json')

loop do
  SEQUENCER.tick
  sleep(0.01)
end
