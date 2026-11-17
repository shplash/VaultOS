#ifndef FALLOUT_IOS_HOST_H_
#define FALLOUT_IOS_HOST_H_

// Implemented in LauncherBridge.mm. Loads the engine framework selected in the
// launcher and runs it. Returns the engine's exit code.
int fallout_ios_launch_selected_engine(int argc, char** argv);

#endif /* FALLOUT_IOS_HOST_H_ */
