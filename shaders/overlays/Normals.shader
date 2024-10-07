// An overlay which displays normals of triangles in view space, from data sampled in the depth texture. Requires dynamic lighting to work (for the depth texture).
//
// Adapted from https://github.com/netri/Neitri-Unity-Shaders (by Neitri, free of charge, free to redistribute)
// Added SPS-I support
// Removed inverse matrix and moved to view space for ease of computation
// Added Fullscreen mode
// https://gist.github.com/bgolus/a07ed65602c009d5e2f753826e8078a0 : we are not in VS but something close, and sufficient for normal-like values. Missing invP.

Shader "Lereldarion/Overlay/Normals" {
    Properties {
        [ToggleUI] _Overlay_Fullscreen("Force Screenspace Fullscreen", Float) = 0
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
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct FragmentInput {
                float4 position_cs : SV_POSITION;
                float4 raw_position_cs : RAW_POSITION_CS;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            void vertex_stage (VertexInput input, out FragmentInput output) {
                UNITY_SETUP_INSTANCE_ID(input);
                output.position_cs = UnityObjectToClipPos(input.position_os);
                output.raw_position_cs = output.position_cs;
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
            }
            
            uniform float _Overlay_Fullscreen;
            uniform float _VRChatMirrorMode;
            uniform float _VRChatCameraMode;
            static const float4 fullscreen_quad_position_cs[4] = {
                float4(-1, -1, UNITY_NEAR_CLIP_VALUE, 1),
                float4(-1,  1, UNITY_NEAR_CLIP_VALUE, 1),
                float4( 1, -1, UNITY_NEAR_CLIP_VALUE, 1),
                float4( 1,  1, UNITY_NEAR_CLIP_VALUE, 1),
            };

            [maxvertexcount(4)]
            void geometry_stage(triangle FragmentInput input[3], uint triangle_id : SV_PrimitiveID, inout TriangleStream<FragmentInput> stream) {
                if(_Overlay_Fullscreen == 1 && _VRChatMirrorMode == 0 && _VRChatCameraMode == 0) {
                    // Fullscreen mode : generate a fullscreen quad for triangle 0 and discard others
                    if (triangle_id == 0) {
                        FragmentInput output = input[0];
                        UNITY_UNROLL
                        for(uint i = 0; i < 4; i += 1) {
                            output.position_cs = fullscreen_quad_position_cs[i];
                            output.raw_position_cs = output.position_cs;
                            stream.Append(output);
                        }
                    }
                } else {
                    // Normal geometry mode : forward triangle
                    stream.Append(input[0]);
                    stream.Append(input[1]);
                    stream.Append(input[2]);
                }
            }

            UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);

            float3 scene_view_position_at(float4 position_cs, float2 screenspace_offset) {
                // Adjust position in screen space (due to w factor)
                position_cs.xy += screenspace_offset * position_cs.w;
                // Calculate screen UV ; here we have a legit CS position so we can use unity macros to handle the SPS-I/non SPS-I differences
                float4 screen_pos = ComputeScreenPos(position_cs);
                float2 screen_uv = screen_pos.xy / screen_pos.w;
                // Read depth, linearizing into view space z depth
                float depth_texture_value = SAMPLE_DEPTH_TEXTURE_LOD(_CameraDepthTexture, float4(screen_uv, 0, 0));
                float linear_depth = LinearEyeDepth(depth_texture_value);
                // Reconstruct view space of displaced pixel, but replace its w-depth by the sampled one
                float4 position_vs = mul(unity_CameraInvProjection, position_cs);
                return position_vs.xyz * linear_depth / position_cs.w;
            }

            fixed4 fragment_stage (FragmentInput i) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // Idea : estimate normals in any non-projected reference frame.
                // View-space is chosen because Unity provides unity_CameraInvProjection to reconstruct view-space from screenspace uvs.
                // Normals are inferred by cross on view-space coordinates of the current pixels and its neighbors.
                
                // Pixel-neighbor offsets.
                float pixel_offset = 1.01; // Artefacts appear if we use 1.0
                float2 screenspace_uv_offset = pixel_offset / _ScreenParams.xy;

                // Sample scene position (view space) for pixels around the current one
                float3 scene_pos_0_0 = scene_view_position_at(i.raw_position_cs, float2(0, 0));
                float3 scene_pos_m_0 = scene_view_position_at(i.raw_position_cs, float2(-screenspace_uv_offset.x, 0));
                float3 scene_pos_0_p = scene_view_position_at(i.raw_position_cs, float2(0, screenspace_uv_offset.y));

                // Compute scene normals at 0 from vectors in different directions / quadrants
                float3 scene_normal_m_p = normalize(cross(scene_pos_0_p - scene_pos_0_0, scene_pos_m_0 - scene_pos_0_0));
                return float4(GammaToLinearSpace(scene_normal_m_p * 0.5 + 0.5), 1);
            }

            ENDCG
        }
    }
}
