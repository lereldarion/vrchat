Shader "Lereldarion/LavaSim/LavaParticleDisplay" {
    Properties {
        //[ToggleUI] _DJ_Enable("Enable output pixels", Float) = 1
        [NoScaleOffset] _LavaSim_State("State texture", 2D) = "" {}
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

            float3 black_body_radiation(float Temperature) {
                float3 color = float3(255.0, 255.0, 255.0);
                color.x = 56100000. * pow(Temperature,(-3.0 / 2.0)) + 148.0;
                color.y = 100.04 * log(Temperature) - 623.6;
                //if (Temperature > 6500.0) color.y = 35200000.0 * pow(Temperature,(-3.0 / 2.0)) + 184.0;
                color.z = 194.18 * log(Temperature) - 1448.6;
                color = clamp(color, 0.0, 255.0)/255.0;
                if (Temperature < 1000.0) color *= Temperature/1000.0;
                return color;
            }

            [instance(32)]
            [maxvertexcount(3)]
            void geometry_stage(point GeometryVertexData input[1], inout TriangleStream<FragmentInput> stream, const uint primitive_id : SV_PrimitiveID, const uint instance : SV_GSInstanceID) {
                UNITY_SETUP_INSTANCE_ID(input[0]);

                uint2 particle_id = uint2(instance, primitive_id); // Cover a square when we increase particle count
                State state = State::load(particle_id);

                float3x3 billboard = referential_from_z(centered_camera_ws - state.position);

                FragmentInput output;
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                // Black body radiation
                output.color = black_body_radiation(state.temperature);

                float2 corners[3] = { float2(1, 0), float2(-0.5, -sqrt(3) / 2), float2(-0.5, sqrt(3) / 2) };
                [unroll] for(uint i = 0; i < 3; i += 1) {
                    output.uv = corners[i];
                    output.position_cs = UnityWorldToClipPos(state.position + 2 * state.size * mul(float3(output.uv, 0), billboard));
                    stream.Append(output); 
                }
            }

            fixed4 fragment_stage(FragmentInput input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                if (length_sq(input.uv) > 0.25) { discard; }
                return fixed4(input.color, 1);
            }
            ENDCG            
        }
    }
}