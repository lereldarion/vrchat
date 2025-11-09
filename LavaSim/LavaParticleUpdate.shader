
Shader "Lereldarion/LavaSim/LavaParticleUpdate" {
    Properties {
        _LavaSim_LavaDensity("Lava particle density (kg/m3, rock+gas bubbles)", Float) = 950

        _LavaSim_Logistic_Distribution_Bounds("Avoid large samples from logistic dsitributions", Range(0, 1)) = 0.95
        
        [Header(Spawn)]
        _LavaSim_Initial_Position("Position", Vector) = (0, 0, 0, 0)
        _LavaSim_Initial_Velocity("Velocity", Vector) = (0, 50, 0, 0)
        _LavaSim_Initial_Velocity_Spread("Velocity spread", Vector) = (1, 1, 1, 0)
        _LavaSim_Initial_Size("Size", Float) = 0.5
        _LavaSim_Initial_Size_Spread("Size spread", Float) = 0.1
        _LavaSim_Initial_Temperature("Temperature", Float) = 1490

        [Header(Wind)]
        _LavaSim_Wind("Wind", Vector) = (0, 0, 0, 0)
        _LavaSim_DragCoefficient("Drag coefficient", Range(0, 2)) = 1
    }
    SubShader {
        Tags {
            "PreviewType" = "Plane"
        }

        ZTest Always
        ZWrite Off
        Blend Off

        CGINCLUDE
        // Hash without Sine https://www.shadertoy.com/view/4djSRW
        // MIT License...
        /* Copyright (c)2014 David Hoskins.

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.*/

        float hash11(float p) {
            p = frac(p * .1031);
            p *= p + 33.33;
            p *= p + p;
            return frac(p);
        }
        float hash12(float2 p) {
            float3 p3  = frac(p.xyx * .1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return frac((p3.x + p3.y) * p3.z);
        }
        float hash13(float3 p3) {
            p3  = frac(p3 * .1031);
            p3 += dot(p3, p3.zyx + 31.32);
            return frac((p3.x + p3.y) * p3.z);
        }
        float hash14(float4 p4) {
            p4 = frac(p4 * float4(.1031, .1030, .0973, .1099));
            p4 += dot(p4, p4.wzxy + 33.33);
            return frac((p4.x + p4.y) * (p4.z + p4.w));
        }
        float2 hash21(float p) {
            float3 p3 = frac(p * float3(.1031, .1030, .0973));
            p3 += dot(p3, p3.yzx + 33.33);
            return frac((p3.xx + p3.yz) * p3.zy);
        }
        float2 hash22(float2 p) {
            float3 p3 = frac(p.xyx * float3(.1031, .1030, .0973));
            p3 += dot(p3, p3.yzx+33.33);
            return frac((p3.xx+p3.yz)*p3.zy);
        }
        float2 hash23(float3 p3) {
            p3 = frac(p3 * float3(.1031, .1030, .0973));
            p3 += dot(p3, p3.yzx + 33.33);
            return frac((p3.xx + p3.yz) * p3.zy);
        }
        float3 hash31(float p) {
            float3 p3 = frac(p * float3(.1031, .1030, .0973));
            p3 += dot(p3, p3.yzx+33.33);
            return frac((p3.xxy+p3.yzz)*p3.zyx); 
        }
        float3 hash32(float2 p) {
            float3 p3 = frac(p.xyx * float3(.1031, .1030, .0973));
            p3 += dot(p3, p3.yxz + 33.33);
            return frac((p3.xxy + p3.yzz) * p3.zyx);
        }
        float3 hash33(float3 p3) {
            p3 = frac(p3 * float3(.1031, .1030, .0973));
            p3 += dot(p3, p3.yxz + 33.33);
            return frac((p3.xxy + p3.yxx) * p3.zyx);
        }
        float4 hash41(float p) {
            float4 p4 = frac(p * float4(.1031, .1030, .0973, .1099));
            p4 += dot(p4, p4.wzxy + 33.33);
            return frac((p4.xxyz + p4.yzzw) * p4.zywx);
        }
        float4 hash42(float2 p) {
            float4 p4 = frac(p.xyxy * float4(.1031, .1030, .0973, .1099));
            p4 += dot(p4, p4.wzxy + 33.33);
            return frac((p4.xxyz + p4.yzzw) * p4.zywx);
        }
        float4 hash43(float3 p) {
            float4 p4 = frac(p.xyzx * float4(.1031, .1030, .0973, .1099));
            p4 += dot(p4, p4.wzxy + 33.33);
            return frac((p4.xxyz + p4.yzzw) * p4.zywx);
        }
        float4 hash44(float4 p4) {
            p4 = frac(p4 * float4(.1031, .1030, .0973, .1099));
            p4 += dot(p4, p4.wzxy + 33.33);
            return frac((p4.xxyz + p4.yzzw) * p4.zywx);
        }
        ENDCG

        Pass {
            Name "Update Lava Particles"

            CGPROGRAM
            #pragma target 5.0

            #pragma vertex DefaultCustomRenderTextureVertexShader
            #pragma fragment fragment_stage

            // https://github.com/cnlohr/flexcrt/blob/master/Assets/flexcrt/flexcrt.cginc
            #define CRTTEXTURETYPE float4
            #include "flexcrt.cginc"

            // From https://github.com/pema99/shader-knowledge/blob/main/attachments/QuadIntrinsics.cginc
            float4 QuadReadAcrossX(float4 value, uint quad_id_x) {
                float4 diff = ddx_fine(value);
                float sign = quad_id_x == 0 ? 1 : -1;
                return (sign * diff) + value;
            }

            struct State {
                uint2 particle_id;
                uint quad_id_x; // using X dimension only

                // Stored
                float3 position;
                float temperature; // Kelvin, at surface of particle
                float3 velocity;
                float size; // Could be from table indexed by particle_id

                static State load(float4 sv_position) {
                    const uint2 screen_pixel_id = (uint2) sv_position.xy;

                    State state;
                    state.particle_id = uint2(screen_pixel_id.x >> 1, screen_pixel_id.y);
                    state.quad_id_x = screen_pixel_id.x & 1;

                    const float4 pixel_0 = _SelfTexture2D[screen_pixel_id];
                    const float4 pixel_x = QuadReadAcrossX(pixel_0, state.quad_id_x);

                    const float4 pixel_a = state.quad_id_x == 0 ? pixel_0 : pixel_x;
                    const float4 pixel_b = state.quad_id_x == 0 ? pixel_x : pixel_0;

                    state.position = pixel_a.rgb;
                    state.temperature = pixel_a.a;
                    state.velocity = pixel_b.rgb;
                    state.size = pixel_b.a;
                    return state;
                }
                float4 store() { return quad_id_x == 0 ? float4(position, temperature) : float4(velocity, size); }
            };

            uniform float _LavaSim_Logistic_Distribution_Bounds;
            uniform float _LavaSim_LavaDensity;

            uniform float3 _LavaSim_Initial_Position;
            uniform float3 _LavaSim_Initial_Position_Spread;
            uniform float3 _LavaSim_Initial_Velocity;
            uniform float3 _LavaSim_Initial_Velocity_Spread;
            uniform float _LavaSim_Initial_Size;
            uniform float _LavaSim_Initial_Size_Spread;
            uniform float _LavaSim_Initial_Temperature;

            uniform float3 _LavaSim_Wind;
            uniform float _LavaSim_DragCoefficient;

            float logistic_sample_from_uniform(float p) {
                p = lerp(0.5, p, _LavaSim_Logistic_Distribution_Bounds); // Allow scale down to clamp tails and large samples
                return log(p / (1.0 - p));
            }
            float3 logistic_sample_from_uniform(float3 p) {
                p = lerp(0.5, p, _LavaSim_Logistic_Distribution_Bounds); // Allow scale down to clamp tails and large samples
                return log(p / (1.0 - p));
            }

            float4 fragment_stage(v2f_customrendertexture input) : SV_Target {
                State state = State::load(input.vertex);
                const float dt = unity_DeltaTime.x;
                const float time = _Time.y;
                const float rcp_dt = unity_DeltaTime.y;

                bool reset = false;
                if(state.position.y <= -1) {
                    // TODO proper, compare pos with heightmap for example
                    reset = true;
                }

                if(!reset) {
                    // Step. For now basic euler.

                    // Assume spherical particle of radius = size
                    const float area = 3.14159265359 * state.size * state.size;
                    const float surface = 4 * area;
                    const float volume = 4. / 3. * area * state.size;
                    const float mass = volume * _LavaSim_LavaDensity;

                    // Air / wind drag.
                    const float3 wind_relative_velocity = _LavaSim_Wind - state.velocity; // TODO use data from wind sim ?
                    const float air_density = 1.16; // kg/m3, at 30°C
                    const float3 drag = (0.5 * air_density * _LavaSim_DragCoefficient * area * length(wind_relative_velocity)) * wind_relative_velocity;
                    
                    // TODO add small random component to velocity over time ?

                    // Temperature exchange with air
                    // TODO

                    state.position += dt * state.velocity;
                    state.velocity += dt * (float3(0, -9.81, 0) + drag / mass);
                } else {
                    // Reset
                    state.position = _LavaSim_Initial_Position; // Logistic sampling does not work well. Maybe uniform on disk, or fixed association from particle_id if square
                    state.velocity = _LavaSim_Initial_Velocity + _LavaSim_Initial_Velocity_Spread * logistic_sample_from_uniform(hash33(float3(state.particle_id, time)));
                    state.size = _LavaSim_Initial_Size + _LavaSim_Initial_Size_Spread * lerp(-1, 1, hash31(float3(state.particle_id, time + 0.1)));
                    state.temperature = _LavaSim_Initial_Temperature;
                }
                return state.store();
            }

            ENDCG
        }
    }
}
