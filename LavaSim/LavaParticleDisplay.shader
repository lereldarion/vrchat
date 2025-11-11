Shader "Lereldarion/LavaSim/LavaParticleDisplay" {
    Properties {
        //[ToggleUI] _DJ_Enable("Enable output pixels", Float) = 1
        [NoScaleOffset] _LavaSim_State("State texture", 2D) = "" {}
        [NoScaleOffset] _LavaSim_Black_Body("Black body texture", 2D) = "" {}
    }
    SubShader {
        Tags {
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
            "IgnoreProjector" = "True"
        }

        Pass {
            Cull Back
            ZTest LEqual
            ZWrite On
            Blend Off

            CGPROGRAM
            #pragma target 5.0
            #pragma multi_compile_instancing

            #pragma vertex vertex_stage
            #pragma geometry geometry_stage
            #pragma fragment fragment_stage

            #include "UnityCG.cginc"

            struct VertexData {
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct GeometryVertexData {
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct FragmentInput {
                float4 position_cs : SV_POSITION;
                float2 uv : UV;
                nointerpolation fixed3 color : BLACK_BODY;

                UNITY_VERTEX_OUTPUT_STEREO
            };

            void vertex_stage(VertexData input, out GeometryVertexData output) {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
            }

            uniform Texture2D<float4> _LavaSim_State;

            uniform Texture2D<float4> _LavaSim_Black_Body;
            uniform SamplerState sampler_LavaSim_Black_Body;

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

            [instance(32)]
            [maxvertexcount(3 * 4)]
            void geometry_stage(point GeometryVertexData input[1], inout TriangleStream<FragmentInput> stream, const uint primitive_id : SV_PrimitiveID, const uint instance : SV_GSInstanceID) {
                UNITY_SETUP_INSTANCE_ID(input[0]);

                [unroll] for(uint j = 0; j < 4; j += 1) {
                    uint2 particle_id = uint2(instance + j * 32, primitive_id); // Cover a square when we increase particle count
                    State state = State::load(particle_id);
    
                    float3x3 billboard = referential_from_z(centered_camera_ws - state.position);
    
                    FragmentInput output;
                    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
    
                    // Black body radiation
                    const float max_temperature = 1500;
                    const float min_temperature = max_temperature - 1024;
                    const float temperature_x = state.temperature - min_temperature;
                    output.color = _LavaSim_Black_Body.SampleLevel(sampler_LavaSim_Black_Body, float2(temperature_x, 0), 0 /*mip*/).rgb;
    
                    float2 corners[3] = { float2(1, 0), float2(-0.5, -sqrt(3) / 2), float2(-0.5, sqrt(3) / 2) };
                    [unroll] for(uint i = 0; i < 3; i += 1) {
                        output.uv = corners[i];
                        output.position_cs = UnityWorldToClipPos(state.position + 2 * state.size * mul(float3(output.uv, 0), billboard));
                        stream.Append(output); 
                    }
                    stream.RestartStrip();
                }
            }

            fixed4 fragment_stage(FragmentInput input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                float len_sq = length_sq(input.uv);
                if (len_sq > 0.25) { discard; }
                return fixed4(input.color * (1 - 4 * len_sq), 1);
            }
            ENDCG            
        }
    }
}