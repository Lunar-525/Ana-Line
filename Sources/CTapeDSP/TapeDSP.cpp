// Magnetic hysteresis derivative and RK4 integration adapted from CHOW Tape Model
// by Jatin Chowdhury, https://github.com/jatinchowdhury18/AnalogTapeModel
// GPL-3.0; see ThirdParty/CHOWTape/LICENSE and NOTICE.md.
// Ana-Line modifications, 2026-10-15: scalar dependency-free implementation,
// stable Langevin evaluation, FIR oversampling, stereo and CHF-inspired profile.
#include "CTapeDSP.h"
#include <array>
#include <algorithm>
#include <cmath>
#include <new>

namespace {
constexpr double pi = 3.14159265358979323846;
constexpr int factor = 4, taps = 63;
struct FIR {
    std::array<double,taps> history{}, coefficients{};
    int position = 0;
    explicit FIR(double cutoff=0.1125) {
        double sum = 0;
        for (int i=0; i<taps; ++i) {
            double x = i-(taps-1)*0.5;
            double w = 0.42-0.5*std::cos(2*pi*i/(taps-1))+0.08*std::cos(4*pi*i/(taps-1));
            coefficients[i] = (x==0 ? 2*cutoff : std::sin(2*pi*cutoff*x)/(pi*x))*w;
            sum += coefficients[i];
        }
        for (auto &v: coefficients) v /= sum;
    }
    double process(double x) {
        history[position] = x;
        double y = 0; int p = position;
        for (int i=0; i<taps; ++i) { y += coefficients[i]*history[p]; if (--p<0) p=taps-1; }
        position = (position+1)%taps;
        return y;
    }
};
struct Magnet {
    // Effective, normalized parameters. These are NOT measured CHF material constants.
    double ms=1, a=0.28, k=0.47875, c=0.97, alpha=0.0016;
    double m=0, h=0, hd=0;
    double derivative(double magnet, double field, double fieldRate) const {
        double q = (field+alpha*magnet)/a;
        double l, lp;
        if (std::abs(q)<0.01) {
            double q2=q*q;
            l=q*(1.0/3-q2/45+2*q2*q2/945);
            lp=1.0/3-q2/15+2*q2*q2/189;
        } else {
            double coth=1/std::tanh(q);
            l=coth-1/q;
            lp=1+1/(q*q)-coth*coth;
        }
        double diff=ms*l-magnet, direction=fieldRate>=0 ? 1 : -1;
        double irreversible=direction*diff>0 ? (1-c)*diff/((1-c)*direction*k-alpha*diff) : 0;
        return fieldRate*(irreversible+c*ms/a*lp)/(1-c*alpha*ms/a*lp);
    }
    double process(double field, double dt) {
        // CHOW's alpha-transform differentiator (dAlpha = 0.75).
        double rate=1.75/dt*(field-h)-0.75*hd;
        double halfField=(field+h)*0.5, halfRate=(rate+hd)*0.5;
        double k1=dt*derivative(m,h,hd);
        double k2=dt*derivative(m+k1*0.5,halfField,halfRate);
        double k3=dt*derivative(m+k2*0.5,halfField,halfRate);
        double k4=dt*derivative(m+k3,field,rate);
        double next=m+(k1+2*k2+2*k3+k4)/6;
        if (!std::isfinite(next) || std::abs(next)>2) { next=0; rate=0; }
        m=next; h=field; hd=rate;
        return m;
    }
};
struct Channel {
    FIR up, down;
    FIR noiseFilter;
    Magnet magnet;
    double loss=0, dcIn=0, dcOut=0, noiseCorrection=1;
    double emphasisLow=0, deInput=0, deOutput=0;
    uint32_t random=1;
    explicit Channel(double rate=48000): noiseFilter(std::min(0.45,20000/rate)) {
        double energy=0;
        for (auto coefficient: noiseFilter.coefficients) energy+=coefficient*coefficient;
        noiseCorrection=1/std::sqrt(energy);
    }
    double white() {
        random ^= random<<13; random ^= random>>17; random ^= random<<5;
        return (double(random)/4294967296.0*2-1)*std::sqrt(3.0);
    }
};
}
struct ALTape {
    double sampleRate, record=1, output=1, noise=1, targetRecord=1, targetOutput=1, targetNoise=1;
    double recordRight=1, targetRecordRight=1;
    // Formulation profile. Reference CHF: sensitivity -0.8 dB, drive 2.5, noise -47.6 dB.
    double sensitivity=1, targetSensitivity=1;
    double drive=2.5, targetDrive=2.5;
    double noiseDB=-47.6, targetNoiseDB=-47.6;
    double headHealth=1, targetHeadHealth=1, tapeHealth=1, targetTapeHealth=1;
    double wearPhase=0;
    bool bypass=false;
    double wetMix=1;
    Channel channels[2];
    explicit ALTape(double rate): sampleRate(rate),channels{Channel(rate),Channel(rate)} { channels[1].random=0x12ab34cd; }
};
extern "C" {
ALTape *al_tape_create(double rate) {
    if (!std::isfinite(rate) || rate<32000 || rate>192000) return nullptr;
    return new(std::nothrow) ALTape(rate);
}
void al_tape_destroy(ALTape *t) { delete t; }
void al_tape_reset(ALTape *t) {
    if (!t) return;
    for (int i=0;i<2;++i) { t->channels[i]=Channel(t->sampleRate); t->channels[i].random=i ? 0x12ab34cd : 1; }
    t->recordRight=t->targetRecordRight; t->record=t->targetRecord; t->output=t->targetOutput; t->noise=t->targetNoise;
    t->sensitivity=t->targetSensitivity; t->drive=t->targetDrive; t->noiseDB=t->targetNoiseDB;
    t->headHealth=t->targetHeadHealth; t->tapeHealth=t->targetTapeHealth; t->wearPhase=0;
    t->wetMix=t->bypass ? 0 : 1;
}
void al_tape_set(ALTape *t,double record,double output,double noise,int bypass) {
    if (!t) return;
    t->targetRecord=std::pow(10,std::clamp(std::isfinite(record)?record:0.0,-24.0,18.0)/20);
    t->targetRecordRight=t->targetRecord;
    t->targetOutput=std::pow(10,std::clamp(std::isfinite(output)?output:0.0,-36.0,6.0)/20);
    t->targetNoise=std::clamp(std::isfinite(noise)?noise:0.0,0.0,1.0);
    t->bypass=bypass!=0;
}
void al_tape_set_right_record_db(ALTape *t,double record) {
    if (t) t->targetRecordRight=std::pow(10,std::clamp(std::isfinite(record)?record:0.0,-24.0,18.0)/20);
}
void al_tape_set_profile(ALTape *t,double sensitivity_db,double drive,double noise_db) {
    if (!t) return;
    double s=std::isfinite(sensitivity_db)?sensitivity_db:-0.8;
    double d=std::isfinite(drive)?drive:2.5;
    double n=std::isfinite(noise_db)?noise_db:-47.6;
    // Relative to the reference CHF formulation (-0.8 dB, drive 2.5, -47.6 dB).
    t->targetSensitivity=std::pow(10,(s+0.8)/20);
    t->targetDrive=std::clamp(d,0.5,8.0);
    t->targetNoiseDB=std::clamp(n,-70.0,-25.0);
}
void al_tape_set_health(ALTape *t,double head,double tape) {
    if (!t) return;
    t->targetHeadHealth=std::clamp(std::isfinite(head)?head:1.0,0.0,1.0);
    t->targetTapeHealth=std::clamp(std::isfinite(tape)?tape:1.0,0.0,1.0);
}
void al_tape_process(ALTape *t,const float *left,const float *right,float *ol,float *orr,int32_t count) {
    if (!t || !left || !right || !ol || !orr || count<=0) return;
    double smoothing=1-std::exp(-1/(0.01*t->sampleRate));
    double dcPole=std::exp(-2*pi*20/t->sampleRate);
    // Effective record/replay emphasis, not a measured CHF equalization curve.
    const double shelfGain=5;
    double shelfPole=std::exp(-2*pi*2500/t->sampleRate);
    double shelfB0=1+(shelfGain-1)*shelfPole;
    // 0 dB Dolby reference is represented by a -18 dBFS peak sine.
    double referenceRMS=std::pow(10,-18.0/20)/std::sqrt(2.0);
    for (int n=0;n<count;++n) {
        double input[2]={left[n],right[n]};
        float *dest[2]={ol+n,orr+n};
        t->recordRight += smoothing*(t->targetRecordRight-t->recordRight);
        t->record += smoothing*(t->targetRecord-t->record);
        t->output += smoothing*(t->targetOutput-t->output);
        t->noise += smoothing*(t->targetNoise-t->noise);
        t->sensitivity += smoothing*(t->targetSensitivity-t->sensitivity);
        t->drive += smoothing*(t->targetDrive-t->drive);
        t->noiseDB += smoothing*(t->targetNoiseDB-t->noiseDB);
        t->wetMix += smoothing*((t->bypass ? 0.0 : 1.0)-t->wetMix);
        t->headHealth += smoothing*(t->targetHeadHealth-t->headHealth);
        t->tapeHealth += smoothing*(t->targetTapeHealth-t->tapeHealth);
        double headWear=1-t->headHealth, tapeWear=1-t->tapeHealth;
        // Effective wear effects, not a measured physical restoration model.
        double cutoff=18000*std::pow(0.18,headWear)*std::pow(0.35,tapeWear);
        double lossPole=std::exp(-2*pi*cutoff/t->sampleRate);
        double wearGain=std::pow(10,(-4*headWear-2*tapeWear)/20);
        double noiseRMS=referenceRMS*std::pow(10,(t->noiseDB+12*tapeWear)/20);
        t->wearPhase += 2*pi*0.73/t->sampleRate;
        if (t->wearPhase>=2*pi) t->wearPhase-=2*pi;
        for (int ch=0;ch<2;++ch) {
            auto &s=t->channels[ch];
            double x=std::isfinite(input[ch]) ? std::clamp(input[ch],-16.0,16.0) : 0;
            double recordGain=(ch==0 ? t->record : t->recordRight)*t->sensitivity;
            s.emphasisLow=(1-shelfPole)*x*recordGain+shelfPole*s.emphasisLow;
            double emphasized=shelfGain*x*recordGain+(1-shelfGain)*s.emphasisLow;
            double y=0;
            for (int j=0;j<factor;++j) {
                double high=s.up.process(j==0 ? emphasized*factor : 0);
                double mag=s.magnet.process(std::clamp(high*t->drive,-8.0,8.0),1/(t->sampleRate*factor));
                y=s.down.process(mag*(0.3155*2.5/t->drive));
            }
            double de=(y-shelfPole*s.deInput+shelfGain*shelfPole*s.deOutput)/shelfB0;
            s.deInput=y; s.deOutput=de;
            s.loss=(1-lossPole)*de+lossPole*s.loss;
            double clean=s.loss-s.dcIn+dcPole*s.dcOut;
            s.dcIn=s.loss; s.dcOut=clean;
            double hiss=s.noiseFilter.process(s.white())*s.noiseCorrection*noiseRMS;
            double ripple=1-0.12*tapeWear*tapeWear*(0.5+0.5*std::sin(t->wearPhase+ch*0.7));
            double wet=(clean*wearGain*ripple+hiss*t->noise)*t->output;
            *dest[ch]=float(x+(wet-x)*t->wetMix);
        }
    }
}
}
