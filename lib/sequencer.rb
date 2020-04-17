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

  def initialize(config)
    @config = config

    # For which part should we show steps and accept MIDI input?
    @focused_part = 0

    @previous_focused_part = 0

    # Parts where this is `true` do not send MIDI data
    @mutes = PARTS.times.map { false }

    # Used for determining what to do on note off
    @muting = PARTS.times.map { false }

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

    # Every pattern starts at C2, velocity 100
    @last_note = PARTS.times.map { [48, 100] }

    @playing_notes = PARTS.times.map { NOTES.times.map { false } }

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
      voice: false,
      play: false,
      record: false,
      clear: false
    }

    @colors = {}

    @note_output = UniMIDI::Output.first
  end

  def tick
    @now = Time.now.to_f
    if @states[:play]
      precise_beat = (((@now - @started_at) * (@bpm / 60.0)) * 4)
      @beat = precise_beat.floor
      @microstep = precise_beat - @beat
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
      perform(@focused_part, index, velocity)
    when :mutes
      unless @mutes[index]
        @muting[index] = true
        @mutes[index] = true

        NOTES.times.each do |note|
          @note_output.puts(0x90 + index, note, 0)
        end
      end
    when :parts
      if @states[:voice]
        note, velocity = @last_note[index]
        perform(index, note, velocity)
      end
      # TODO: If any performance notes are pressed, queue part focus change
      # but don't change it yet
      @previous_focused_part = @focused_part
      @focused_part = index
    when :patterns
      part = (index / PATTERNS.to_f).floor
      pattern = index % PATTERNS
      if @states[:play]
        @queued_sequences[part] = [pattern]
      else
        @sequences[part] = [[pattern], 0]
      end
    when :steps
      @written_steps[index] = false
      # TODO: If a previous step is also pressed, set gate length for that step
      # to the distance to this step
      pattern, _ = current_step(@focused_part)
      pattern_index = @focused_part * PATTERNS + pattern
      if @presses[[:patterns, pattern_index]]
        @pattern_lengths[pattern_index] = index + 1
      end
    when :voice, :play, :record, :clear
      @states[label] = !@states[label]
      handle_play if label == :play
    end

    @presses[[label, index]] = [velocity, @now]
  end

  def handle_note_off(label, index)
    return unless @presses[[label, index]]

    held = @now - @presses[[label, index]][1] >= HOLD_DURATION

    case label
    when :performance
      @note_output.puts(0x80 + @focused_part, index, 0)
      # TODO: If no more performance notes are pressed, change part focus to
      # queued part focus
    when :mutes
      if @muting[index]
        @muting[index] = false
      else
        @mutes[index] = false
      end
    when :parts
      if @states[:voice]
        # TODO: @last_note could change between voiced part note on and voiced part note off
        note, _ = @last_note[index]
        @note_output.puts(0x80 + index, note, 0)
      end
      if held
        # TODO: Support queued focus
        @focused_part = @previous_focused_part
      end
    when :patterns
      # TODO: Pattern chaining
      # part = (index / PATTERNS.to_f).floor
      # if @presses.none? { |(p_label, p_index), _| p_label == label && p_index != index && (p_index / PATTERNS.to_f).floor == part }
      #   @queued_sequences[part] = @draft_sequences[part]
      #   @draft_sequences[part] = []
      # end
    when :steps
      pattern, _ = current_step(@focused_part)
      unless @presses[[:patterns, @focused_part * PATTERNS + pattern]]
        if @patterns[@focused_part][pattern][index].all?(&:zero?)
          note, velocity = @last_note[@focused_part]
          @patterns[@focused_part][pattern][index][note] = velocity
        else
          unless @written_steps[index] || @presses.any? { |(p_label, p_index), _| p_label == label && p_index != index  }
            @patterns[@focused_part][pattern][index] = NOTES.times.map { 0 }
          end
        end
      end
    when :voice, :play, :record, :clear
      if held
        @states[label] = !@states[label]
        handle_play if label == :play
      end
    end

    @presses.delete([label, index])
  end

  def perform(part, note, velocity)
    @note_output.puts(0x90 + part, note, velocity)

    @last_note[part] = [note, velocity]

    if @states[:record]
      pattern, step = current_step(part)
      step += 1 if @microstep >= 0.5
      step = 0 if step >= @pattern_lengths[part * PATTERNS + pattern]
      @patterns[part][pattern][step][note] = velocity
    elsif (pressed_step = @presses.find { |(label, _), _| label == :steps })
      pattern, _ = current_step(part)
      step = pressed_step[0][1]
      @patterns[part][pattern][step][note] = velocity
      @written_steps[step] = true
    end
  end

  # This is called only when @states[:play] changes
  def handle_play
    if @states[:play]
      @started_at = @now
      @beat = (((@now - @started_at) * (@bpm / 60.0)) * 4).floor
      PARTS.times.each do |part|
        @sequences[part][1] = @beat
      end
    else
      unless @presses[[:record, 0]]
        @states[:record] = false
      end
      PARTS.times.each do |part|
        NOTES.times.each do |note|
          @note_output.puts(0x80 + part, note, 0)
        end
      end
    end
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
    @queued_sequences.each_with_index do |sequences, part|
      next if sequences.size.zero?
      _, step = current_step(part)
      next unless step.zero?
      @sequences[part] = [sequences, @beat]
      @queued_sequences[part] = []
    end

    pattern, step = current_step(@focused_part)

    if @states[:clear]
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
          # This is a hold; do nothing
          next if velocity == -1

          if @playing_notes[part][note]
            notes += [0x80 + part, note, 0]
            @playing_notes[part][note] = false
          end

          if velocity > 0 && !@mutes[part]
            @playing_notes[part][note] = true
            notes += [0x90 + part, note, velocity]
          end
        end
      end
      @note_output.puts(notes)
    end
  end

  def current_step(part)
    sequence, started_at = @sequences[part]
    lengths = sequence.map { |pattern| @pattern_lengths[part * PATTERNS + pattern] }
    current_step = (@beat - started_at) % lengths.inject(:+)
    current_pattern =
      sequence.find do |pattern|
        length = @pattern_lengths[part * PATTERNS + pattern]
        next true if current_step < length
        current_step -= length
        false
      end
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
      when :mutes
        PARTS.times.each do |part|
          set_color(label, part, @mutes[part] ? 127 : 0)
        end
      when :parts
        PARTS.times.each do |part|
          set_color(label, part, part == @focused_part ? 127 : 0)
        end
      when :patterns
        PARTS.times.each do |part|
          active_pattern = current_step(part).first
          PATTERNS.times.each do |pattern|
            color =
              if active_pattern == pattern
                3
              elsif @queued_sequences[part].include?(pattern)
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
      when :mute, :voice, :play, :record, :clear
        set_color(label, 0, @states[label] ? 127 : 0)
      end
    end
  end
end
