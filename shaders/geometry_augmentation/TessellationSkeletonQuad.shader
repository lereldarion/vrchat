// Skeleton of using the DX11 tessellation pipeline
Shader "Lereldarion/TesselationSkeletonQuad" {
    Properties
    {
        _Color ("Color", Color) = (1,1,1,1)
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        Pass {
            CGPROGRAM
            #pragma target 5.0
            #pragma multi_compile_instancing
            
            #pragma vertex vertex_stage
            #pragma hull hull_control_point_stage
            #pragma domain domain_stage
            #pragma fragment fragment_stage

            #include "UnityCG.cginc"

            struct VertexData {
                float3 position_os : POSITION;
                float3 normal_os : NORMAL;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationVertexData {
                float3 position_os : CP_POSITION;
                float3 normal_os : NORMAL;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationFactors {
                float edge[4] : SV_TessFactor; // Edge association [u=0, v=0, u=1, v=1]
                float inside[2] : SV_InsideTessFactor; // Axis [u,v]
                // Vertex ordering is thus chosen as [(0, 1), (0, 0), (1, 0), (1, 1)] in (u,v coordinates)
            };

            struct Interpolators {
                float4 pos : SV_POSITION; // CS, name required by stupid TRANSFER_SHADOW macro
                UNITY_VERTEX_OUTPUT_STEREO
            };

            // Constants

            uniform fixed4 _Color;
            
            // stages

            TessellationVertexData vertex_stage (const VertexData input) {
                TessellationVertexData output;

                UNITY_SETUP_INSTANCE_ID (input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);

                output.position_os = input.position_os;
                output.normal_os = input.normal_os;
                return output;
            }

            [domain ("quad")]
            [outputcontrolpoints (4)]
            [outputtopology ("triangle_cw")]
            [patchconstantfunc ("hull_patch_constant_stage")]
            [partitioning ("integer")]
            TessellationVertexData hull_control_point_stage (const InputPatch<TessellationVertexData, 4> vertex, uint id : SV_OutputControlPointID) {
                return vertex[id];
            }

            TessellationFactors hull_patch_constant_stage (const OutputPatch<TessellationVertexData, 4> cp) {
                TessellationFactors factors;
                [unroll] for (int i = 0; i < 4; ++i) {
                    factors.edge[i] = 2;
                }
                factors.inside[0] = 2;
                factors.inside[1] = 2;
                return factors;
            }

            #define UV_BARYCENTER(cp, accessor) lerp (lerp (cp[1] accessor, cp[2] accessor, uv.x), lerp (cp[0] accessor, cp[3] accessor, uv.x), uv.y)

            [domain ("quad")]
            Interpolators domain_stage (const TessellationFactors factors, const OutputPatch<TessellationVertexData, 4> cp, float2 uv : SV_DomainLocation) {
                Interpolators output;

                UNITY_SETUP_INSTANCE_ID (cp[0]);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                float3 position_os = UV_BARYCENTER (cp, .position_os);

                // Classic vertex stage transformations
                output.pos = UnityObjectToClipPos (position_os);
                float3 normal_os = UV_BARYCENTER (cp, .normal_os);

                return output;
            }

            fixed4 fragment_stage (Interpolators input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX (input);
                return _Color;
            }

            ENDCG
        }
    }
}
