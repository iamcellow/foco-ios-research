#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float lumin(float3 rgb) { return dot(rgb,float3(.2126,.7152,.0722)); }
float4 moments(sample_t rgb,sample_t depth) {
    float y=sqrt(clamp(lumin(rgb.rgb),0.f,1.f)), z=depth.r;
    return float4(y,z,y*y,1);
}
float4 crossMoment(sample_t rgb,sample_t depth) {
    float v=sqrt(clamp(lumin(rgb.rgb),0.f,1.f))*depth.r;
    return float4(v,v,v,1);
}
float4 coefficients(sample_t mean,sample_t cross) {
    float a=(cross.r-mean.r*mean.g)/(max(0.f,mean.b-mean.r*mean.r)+.0015);
    return float4(a,mean.g-a*mean.r,0,1);
}
float4 refine(sample_t rgb,sample_t ab,sample_t prior) {
    float y=sqrt(clamp(lumin(rgb.rgb),0.f,1.f));
    float z=clamp(ab.r*y+ab.g, max(0.f,prior.r-.28),min(1.f,prior.r+.28));
    return float4(z,z,z,1);
}
float4 fuse(sample_t model,sample_t sensor,float slope,float intercept) {
    float adjusted=sensor.r*slope+intercept;
    float weight=(sensor.r>0 && isfinite(sensor.r)) ? .4*(1-smoothstep(.035,.16,abs(adjusted-model.r))) : 0;
    float z=mix(model.r,clamp(adjusted,0.f,1.f),weight);
    return float4(z,z,z,1);
}
float4 plane(sample_t rgb,sample_t depth,float center,float width) {
    float a=max(0.f,1.f-abs(depth.r-center)/width);
    return float4(rgb.rgb*a,a);
}
float4 overPlane(sample_t back,sample_t layer,sample_t z,float center,float width) {
    float coverage=clamp(layer.a,0.f,1.f);
    float local=max(0.f,1.f-abs(z.r-center)/width);
    float a=clamp(max(coverage,local*min(1.f,coverage*6)),0.f,1.f);
    return float4(mix(back.rgb,layer.rgb/max(.00001f,coverage),a),1);
}
float4 focusDetail(sample_t result,sample_t original,sample_t depth,float focus,float strength) {
    float a=1-smoothstep(.25,1.2,max(0.f,abs(depth.r-focus)-.032)*strength);
    return float4(mix(result.rgb,original.rgb,a),1);
}
float4 highlights(sample_t s,float exposure) {
    float y=lumin(s.rgb)*exp2(exposure);
    return float4(s.rgb*smoothstep(.36,1.2,y),1);
}
float hash(float2 p,float seed){
    float3 q=fract(float3(p.xyx)*.1031+float3(seed*.000013));
    q+=dot(q,q.yzx+33.33);
    return fract((q.x+q.y)*q.z);
}
float noiseCell(float2 pos,float seed) {
    float2 cell=floor(pos),u=fract(pos);
    u=u*u*(3-2*u);
    return mix(mix(hash(cell,seed),hash(cell+float2(1,0),seed),u.x),
               mix(hash(cell+float2(0,1),seed),hash(cell+1,seed),u.x),u.y)-.5;
}
float4 develop(sample_t photo,sample_t halo,sample_t hot,float4 tone,float4 texture,float4 tint,
               float exposure,float grainScale,float seed,destination dst) {
    float3 input=max(photo.rgb,0.f)*exp2(exposure);
    float3 glow=max(halo.rgb-hot.rgb,0.f)*exp2(exposure);
    input+=glow*(texture.y*float3(1,.22,.045)+texture.z);
    float y=max(.000001f,lumin(input));
    float3 col=mix(float3(y),input,tone.y)*tint.rgb;
    float l=max(.000001f,lumin(col));
    float v=.18*pow(l/.18,tone.x);
    v=v/(1+tone.z*v)+tone.w*exp(-8*v);
    col*=v/l;
    // Compress excess chroma along the constant-luminance axis before SDR encoding.
    // Neutral is the identity profile; preserve its conventional exposure response.
    if (tone.z>0 && v<1) {
        float peak=max(col.r,max(col.g,col.b));
        float limit=max(.00001f,1-v);
        float distance=max(0.f,peak-v)/limit;
        if (distance>.82) {
            float knee=.82+.18*(1-exp(-(distance-.82)/.18));
            col=v+(col-v)*(knee/distance);
        }
    }
    float2 p=dst.coord()/max(.08f,texture.w*grainScale);
    float n=noiseCell(p,seed)+.36*noiseCell(p*.51,seed+1123);
    float3 dye=float3(noiseCell(p*.88,seed+9),noiseCell(p*.96,seed+137),noiseCell(p*1.04,seed+71));
    float footprint=min(1.f,texture.w*grainScale);
    float a=texture.x*footprint*sqrt(max(.0001f,v))*(1-smoothstep(.65,1.45,v));
    col+=a*(n+.15*tone.y*dye);
    return float4(max(col,0.f),1);
}
}}
