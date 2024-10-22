// Display TBN as lines for objects.
// Useful for debugging

Shader "Lereldarion/TBN" {
    Properties {
        _Length("Reference frame vector length", Range(0, 1)) = 1
        [ToggleUI] _DisplayMeshBinormal("Display mesh binormal (with tangent.w) instead of cross", Float) = 0

    }
    SubShader {
        Tags {
            "Queue" = "Overlay"
            "RenderType" = "Overlay"
            "VRCFallback" = "Hidden"
            "PreviewType" = "Plane"
        }
        
        Cull Off
        ZWrite Off
        ZTest Less
        
        Pass {
            CGPROGRAM
            #pragma vertex vertex_stage
            #pragma geometry geometry_stage
            #pragma fragment fragment_stage
            #pragma multi_compile_instancing
            
            #include "UnityCG.cginc"
            #pragma target 5.0

            struct VertexInput {
                float4 position_os : POSITION;
                float3 normal_os : NORMAL;
                float4 tangent_os : TANGENT;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct FragmentInput {
                float4 position : SV_POSITION; // CS as rasterizer input, screenspace as fragment input
                float3 color : EDGE_COLOR;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            void vertex_stage (VertexInput input, out VertexInput output) {
                output = input;
            }
            
            uniform float _Length;
            uniform float _DisplayMeshBinormal;

            void vector_os(inout LineStream<FragmentInput> stream, float3 v, float3 color) {
                FragmentInput output;
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                output.color = color;

                output.position = UnityObjectToClipPos(float3(0, 0, 0));
                stream.Append(output);
                
                output.position = UnityObjectToClipPos(v * _Length);
                stream.Append(output);

                stream.RestartStrip();
            }

            [maxvertexcount(6)]
            void geometry_stage(triangle VertexInput input[3], uint triangle_id : SV_PrimitiveID, inout LineStream<FragmentInput> stream) {
                UNITY_SETUP_INSTANCE_ID(input[0]);
                if (triangle_id == 0) {
                    vector_os(stream, input[0].tangent_os.xyz, float3(1, 0, 0));
                    float3 binormal = cross(input[0].normal_os, input[0].tangent_os.xyz);
                    if (_DisplayMeshBinormal) {
                        binormal *= input[0].tangent_os.w;
                    }                
                    vector_os(stream, binormal, float3(0, 1, 0));
                    vector_os(stream, input[0].normal_os, float3(0, 0, 1));                    
                }
            }

            fixed4 fragment_stage (FragmentInput input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                return fixed4(input.color, 1);
            }
            ENDCG
        }
    }
}
