Shader "Lereldarion/LavaSim/LavaParticleDisplay" {
    Properties {
        [NoScaleOffset] _LavaSim_State("State texture", 2D) = "" {}
        
        [Header(Black Body Emission)]
        [NoScaleOffset] _LavaSim_Black_Body("Black body texture", 2D) = "" {}
        _LavaSim_Black_Body_Scale("Black body emission scaling", Range(0, 1)) = 0.04

        [Header(Visuals)]
        _LavaSim_Rotation_Speed_Spread("Rotation speed range", Float) = 1
        _LavaSim_Particle_Scale("Visual scale", Float) = 1
    }
    SubShader {
        Tags {
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
            "IgnoreProjector" = "True"
        }

        Pass {
            Cull Off//Back
            ZTest LEqual
            ZWrite On
            Blend Off

            CGPROGRAM
            #pragma target 5.0
            #pragma multi_compile_instancing

            #pragma vertex vertex_stage
            #pragma fragment fragment_stage

            #include "UnityCG.cginc"

            struct VertexData {
                // Position is xy only, billboard shape
                // Particle id is z bit packed.
                float3 position_and_packed_id : POSITION;

                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct FragmentInput {
                float4 position_cs : SV_POSITION;
                float2 uv : UV;
                nointerpolation fixed3 color : BLACK_BODY;

                UNITY_VERTEX_OUTPUT_STEREO
            };

            uniform Texture2D<float4> _LavaSim_State;

            uniform Texture2D<float4> _LavaSim_Black_Body;
            uniform SamplerState sampler_LavaSim_Black_Body;
            uniform float _LavaSim_Black_Body_Scale;

            uniform float _LavaSim_Rotation_Speed_Spread;
            uniform float _LavaSim_Particle_Scale;

            struct State {
                float3 position;
                float temperature; // Kelvin, at surface of particle
                float3 velocity;
                float size; // Could be from table indexed by particle_id

                static State load(uint2 particle_id) {
                    const float4 pixel_a = _LavaSim_State[uint2(2 * particle_id.x, particle_id.y)];
                    const float4 pixel_b = _LavaSim_State[uint2(2 * particle_id.x + 1, particle_id.y)];

                    State state;
                    state.position = pixel_a.rgb;
                    state.temperature = pixel_a.a;
                    state.velocity = pixel_b.rgb;
                    state.size = pixel_b.a;
                    return state;
                }
            };

            #if defined(USING_STEREO_MATRICES)
            static float3 centered_camera_ws = (unity_StereoWorldSpaceCameraPos[0] + unity_StereoWorldSpaceCameraPos[1]) / 2;
            #else
            static float3 centered_camera_ws = _WorldSpaceCameraPos.xyz;
            #endif

            float length_sq(float3 v) { return dot(v, v); }
            float length_sq(float2 v) { return dot(v, v); }

            float3x3 referential_from_z(float3 z) {
                z = normalize(z);
                float3 x = cross(z, float3(0, 1, 0)); // Cross with world up for the sides
                if(length_sq(x) == 0) {
                    x = float3(1, 0, 0); // Fallback if aligned
                } else {
                    x = normalize(x);
                }
                float3 y = cross(x, z);
                return float3x3(x, y, z);
            }

            // Hash without Sine https://www.shadertoy.com/view/4djSRW
            // MIT License ; Copyright (c)2014 David Hoskins.
            float2 hash21(float p) {
                float3 p3 = frac(p * float3(.1031, .1030, .0973));
                p3 += dot(p3, p3.yzx + 33.33);
                return frac((p3.xx + p3.yz) * p3.zy);
            }

            void vertex_stage(VertexData input, out FragmentInput output) {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                const uint packed_particle_id = (uint) input.position_and_packed_id.z;

                const uint2 particle_id = uint2(packed_particle_id & 0x3FF, (packed_particle_id >> 10) & 0x3FF);
                State state = State::load(particle_id);

                float3x3 billboard = referential_from_z(centered_camera_ws - state.position);

                float rotation_speed = _LavaSim_Rotation_Speed_Spread * lerp(-1, 1, hash21(particle_id));
                float2 sin_cos;
                sincos(rotation_speed * _Time.y, sin_cos.x, sin_cos.y);
                float2x2 rotation_matrix = float2x2(sin_cos.y, -sin_cos.x, sin_cos.x, sin_cos.y);
                
                // Black body radiation
                const float temperature_range = 1024;
                const float max_temperature = 1600;
                const float min_temperature = max_temperature - temperature_range;
                const float temperature_x = (state.temperature - min_temperature) / temperature_range;
                output.color = _LavaSim_Black_Body.SampleLevel(sampler_LavaSim_Black_Body, float2(temperature_x, 0), 0 /*mip*/).rgb * _LavaSim_Black_Body_Scale;

                output.uv = input.position_and_packed_id.xy;
                float2 billboard_pos = _LavaSim_Particle_Scale * state.size * mul(rotation_matrix, input.position_and_packed_id.xy);
                output.position_cs = UnityWorldToClipPos(state.position +  mul(float3(billboard_pos, 0), billboard));
            }

            fixed4 fragment_stage(FragmentInput input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                float len_sq = length_sq(input.uv);
                return fixed4(input.color * max(1 - len_sq, 0), 1);
            }
            ENDCG            
        }
    }
}