#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ALTape ALTape;
ALTape *al_tape_create(double sample_rate);
void al_tape_destroy(ALTape *tape);
void al_tape_reset(ALTape *tape);
// Parameters are applied on the processing thread, not concurrently with process.
void al_tape_set(ALTape *tape, double record_db, double output_db, double noise, int bypass);
void al_tape_set_right_record_db(ALTape *tape, double record_db);
// Per-formulation profile. sensitivity_db is the relative 400 Hz sensitivity
// (the reference CHF formulation is -0.8 dB). drive scales the hysteresis input
// to move the saturation point: smaller drive reaches a higher MOL. noise_db is
// the unweighted bias-noise level in dB below the nominal reference.
// These are effective, audible differences between formulations, not a full fit
// of each tape's measured MOL/SOL curve.
void al_tape_set_profile(ALTape *tape, double sensitivity_db, double drive, double noise_db);
// Effective head/tape health in [0, 1]; non-finite values restore healthy condition.
void al_tape_set_health(ALTape *tape, double head_health, double tape_health);
// Planar stereo; in-place buffers are supported. No allocation or locking.
void al_tape_process(ALTape *tape, const float *left, const float *right,
                     float *out_left, float *out_right, int32_t frames);
#ifdef __cplusplus
}
#endif
