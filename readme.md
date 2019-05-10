## Random Walkers

This Norns script uses a simple random walk algorithm to set a number of agents in motion across the screen. As walkers get near each other, they emit sound that increases in frequency and amplitude.

### Notes
* Both sound and system parameters are available in the Params menu, including settings for the number of walkers and the threshold at which they begin emitting sound.
* This script does not use BeatClock for tempo but operates at a variable speed measured in milliseconds.