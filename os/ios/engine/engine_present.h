#ifndef FALLOUT_IOS_ENGINE_PRESENT_H_
#define FALLOUT_IOS_ENGINE_PRESENT_H_

#ifdef __cplusplus
extern "C" {
#endif

int fallout_engine_present_frame(const void* pixels, int pitch, int width, int height);

#ifdef __cplusplus
}
#endif

#endif /* FALLOUT_IOS_ENGINE_PRESENT_H_ */
