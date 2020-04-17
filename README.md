# Sequencer

## A flexible multi-device MIDI sequencer for live electronic music performance

**This is a work in progress!**

The workflow is very heavily inspired by [Novation Circuit](https://novationmusic.com/en/circuit/circuit) with a dash of [Elektron Model:Cycles](https://www.elektron.se/products/modelsamples/)—patterns are set and triggered on a [Launchpad Mini Mk3](https://novationmusic.com/en/launch/launchpad-mini), parts are selected and can be played on a [MIDI Fighter 3D](https://www.midifighter.com/#3D), and melodies are played on a [Korg Microkey 25](https://www.korg.com/us/products/computergear/microkey/), but that’s just because those are the things I happen to have—it’s designed to work with any combination of devices, so long as they have some kind of visual feedback.

With the devices I've chosen, I'm planning for 8 polyphonic parts with 4 32-step patterns each.

A big goal of this is one-function-per-control. The first version put _everything_ on the MIDI Fighter 3D behind tons of modes and pages, for a workflow similar to how Pocket Operators work, and it was an interesting design challenge but not fun to use.

I'm writing this sequencer in Ruby, and it's using macOS's native MIDI bus to communicate with Ableton Live in my demo, but it could send MIDI to just about anything that accepts it.

You're welcome to try this out, but there are no instructinos for running it and I offer no guarantees that it will work for you. I cannot offer any tech support right now. Hopefully this changes eventually.

## TODO

- Pattern chains
- Support chords in Voiced mode?
- Adjust gate length on steps
- Swing
- Write unit tests
