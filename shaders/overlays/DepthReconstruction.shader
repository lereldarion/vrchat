// Experiments with depth reconstruction.
//
// Initially adapted from https://github.com/netri/Neitri-Unity-Shaders (by Neitri, free of charge, free to redistribute)
// Added SPS-I support
// Removed inverse matrix and moved to view space for ease of computation. Sadly uses the invalid CameraInvProjection.
// Added Fullscreen mode
// Tried bgolus strategy but SPS-I artefacts :( https://gist.github.com/bgolus/a07ed65602c009d5e2f753826e8078a0
// Lots of documentation and tests, and then use the camera_ray + depth strategy but allowing depth sample with shift.
// Using VS for ray interpolation : less math, and should reduce floating errors. Already reduces artefacting at close range compared to interpolated WS ray.

Shader "Lereldarion/Overlay/DepthReconstruction" {
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
                float4 position : SV_POSITION; // CS as rasterizer input, screenspace as fragment input
                float3 position_vs : POSITION_VS;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            void vertex_stage (VertexInput input, out FragmentInput output) {
                UNITY_SETUP_INSTANCE_ID(input);
                output.position_vs = UnityObjectToViewPos(input.position_os);
                output.position = UnityViewToClipPos(output.position_vs);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
            }
            
            uniform float _Overlay_Fullscreen;
            uniform float _VRChatMirrorMode;
            uniform float _VRChatCameraMode;

            [maxvertexcount(4)]
            void geometry_stage(triangle FragmentInput input[3], uint triangle_id : SV_PrimitiveID, inout TriangleStream<FragmentInput> stream) {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input[0]);
                if(_Overlay_Fullscreen == 1 && _VRChatMirrorMode == 0 && _VRChatCameraMode == 0) {
                    // Fullscreen mode : generate a fullscreen quad for triangle 0 and discard others
                    if (triangle_id == 0) {
                        FragmentInput output = input[0];

                        // Generate in VS close to near clip plane. Having non CS positions is essential to return to WS later.
                        float2 quad[4] = { float2(-1, -1), float2(-1, 1), float2(1, -1), float2(1, 1) };
                        float near_plane_z = -_ProjectionParams.y;
                        float2 tan_half_fov = 1 / unity_CameraProjection._m00_m11; // https://jsantell.com/3d-projection/
                        // Add margins, mostly in case of oblique P matrices or similar
                        float quad_z = near_plane_z * 2; // z margin
                        float quad_xy = quad_z * tan_half_fov * 1.2; // xy margin

                        UNITY_UNROLL
                        for(uint i = 0; i < 4; i += 1) {
                            output.position_vs = float4(quad[i] * quad_xy, quad_z, 1);
                            output.position = UnityViewToClipPos(output.position_vs);
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
            float4 _CameraDepthTexture_TexelSize;

            struct SceneReconstruction {
                float2 pixel;
                float3 ray_vs;
                float3 ray_dx_vs;
                float3 ray_dy_vs;

                static SceneReconstruction init(FragmentInput input) {
                    SceneReconstruction o;
                    o.pixel = input.position.xy;
                    o.ray_vs = input.position_vs / input.position.w;
                    // Use derivatives to get ray for neighbouring pixels.
                    // This is exact because ray is linear on a fragment.
                    // TODO improve by using ddx/ddy on separate position_vs / position.w and then divide ?
                    o.ray_dx_vs = ddx(o.ray_vs);
                    o.ray_dy_vs = ddy(o.ray_vs);
                    return o;
                }

                float3 position_vs() {
                    return position_vs(float2(0, 0));
                }
                
                float3 position_vs(float2 pixel_shift) {
                    // HLSLSupport.hlsl : DepthTexture is a TextureArray in SPS-I, so its size should be safe to use to get uvs.
                    float3 shifted_ray_vs = ray_vs + pixel_shift.x * ray_dx_vs + pixel_shift.y * ray_dy_vs;
                    float2 uv = (pixel + pixel_shift) * _CameraDepthTexture_TexelSize.xy;
                    float raw = SAMPLE_DEPTH_TEXTURE_LOD(_CameraDepthTexture, float4(uv, 0, 0)); // [0,1]
                    return shifted_ray_vs * LinearEyeDepth(raw);
                }
            };

            fixed4 fragment_stage (FragmentInput input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                SceneReconstruction sr = SceneReconstruction::init(input);
                float3 vs_0_0 = sr.position_vs();

                float3 ws = mul(unity_MatrixInvV, float4(vs_0_0, 1)).xyz;
                //return fixed4(frac(ws), 1);
                
                float3 vs_m_0 = sr.position_vs(float2(-1, 0));
                float3 vs_0_p = sr.position_vs(float2(0, 1));

                // Normals : cross product between pixel reconstructed VS, then WS
                float3 normal_dir_vs = cross(vs_0_p - vs_0_0, vs_m_0 - vs_0_0);
                float3 normal_ws = normalize(mul((float3x3) unity_MatrixInvV, normal_dir_vs));
                return fixed4(GammaToLinearSpace(normal_ws * 0.5 + 0.5), 1);
                
                float3 vs_p_0 = sr.position_vs(float2(1, 0));
                float3 vs_0_m = sr.position_vs(float2(0, -1));
                
                float3 normal_vs_m_p = normalize(cross(vs_0_p - vs_0_0, vs_m_0 - vs_0_0));
                float3 normal_vs_p_m = normalize(cross(vs_0_m - vs_0_0, vs_p_0 - vs_0_0));
                float3 normal_vs_p_p = normalize(cross(vs_p_0 - vs_0_0, vs_0_p - vs_0_0));
                
                // Highlight differences in normals. Does not need WS for that.
                float3 o = 1;
                float sum_normal_differences = dot(o, abs(normal_vs_p_p - normal_vs_m_p)) + dot(o, abs(normal_vs_p_m - normal_vs_m_p));
                float c = saturate(sum_normal_differences);
                //c = c * c; // Eliminate noise but kills low diff edges
                return float4(c.xxx, 1);
            }

            ///////////////////////////////////////////////////////////////////
            // Other strategies

            // Strategy that rebuilds the worldspace from frustum clip planes.
            // Fails due to unity_CameraWorldClipPlanes[6] being probably abandonned and buggy :
            // - almost no google matches, probably no users
            // - Far plane equation is wrong in the editor. Used parallel near plane with correction factors for tests.
            // - No Stereo matrix support spotted in headers or decompiled references.
            // Predictably the value is unusable in VR.
            struct WorldspaceCameraFrustum {
                float3 camera_to_far_plane_corner[2][2] : WS_CAMERA_FRUSTUM;

                static WorldspaceCameraFrustum init() {
                    WorldspaceCameraFrustum wscf;
                    // Find worldspace position for each corner of the far plane in the camera frustum.
                    wscf.camera_to_far_plane_corner[0][0] = compute_camera_to_far_plane_corner(2, 0); // bottom left
                    wscf.camera_to_far_plane_corner[1][0] = compute_camera_to_far_plane_corner(2, 1); // bottom right
                    wscf.camera_to_far_plane_corner[0][1] = compute_camera_to_far_plane_corner(3, 0); // top left
                    wscf.camera_to_far_plane_corner[1][1] = compute_camera_to_far_plane_corner(3, 1); // top right
                    return wscf;
                }
                static float3 compute_camera_to_far_plane_corner(int side0, int side1) {
                    // Use worldspace clip planes from unity.
                    // Use cross from intersecting side planes to find the corner direction vector, then renormalize between camera and far plane.
                    // We do not care about the direction of the cross, it will be flipped to correct orientation by the renormalization.
                    float3 intersection_direction = cross(unity_CameraWorldClipPlanes[side0].xyz, unity_CameraWorldClipPlanes[side1].xyz);
                    float4 far_plane_eqn = unity_CameraWorldClipPlanes[5];
                    return (dot(float4(_WorldSpaceCameraPos, 1), far_plane_eqn) / dot(intersection_direction, far_plane_eqn.xyz)) * intersection_direction;
                }

                float3 worldspace_from_screenspace_uv_depth(float2 uv, float depth_01) {
                    float3 camera_to_far_plane = lerp(
                        lerp(camera_to_far_plane_corner[0][0], camera_to_far_plane_corner[0][1], uv.y),
                        lerp(camera_to_far_plane_corner[1][0], camera_to_far_plane_corner[1][1], uv.y),
                        uv.x
                    );
                    return _WorldSpaceCameraPos + camera_to_far_plane * depth_01;
                }

                float3 worldspace_scene_position(float2 pixel) {
                    // HLSLSupport.hlsl : DepthTexture is a TextureArray in SPS-I, so its size should be safe to use to get uvs.
                    float2 uv = pixel * _CameraDepthTexture_TexelSize.xy;
                    float raw = SAMPLE_DEPTH_TEXTURE_LOD(_CameraDepthTexture, float4(uv, 0, 0)); // [0,1]
                    if(!(0 < raw && raw < 1)) { discard; }
                    uv.y = 1 - uv.y;
                    return worldspace_from_screenspace_uv_depth(uv, Linear01Depth(raw));
                }
            };

            // Strategy to synthetise VS with inverse of P from CS.
            // https://gist.github.com/bgolus/a07ed65602c009d5e2f753826e8078a0
            // InvP is not available, so it uses CameraInvProjection which is "generally" close, up to a rotate or something.
            // This works ok in editor (3D and with mock HMD) but fails in VR ; probably due to oblique projection matrices being individually rotated.
            // Without a real InvP including the API-specific changes (HMD stuff), this will never work.
            float3 scene_position_bgolus_vs(float2 pixel) {
                // HLSLSupport.hlsl : DepthTexture is a TextureArray in SPS-I, so its size should be safe to use to get uvs.
                float2 uv = pixel * _CameraDepthTexture_TexelSize.xy;
                float raw = SAMPLE_DEPTH_TEXTURE_LOD(_CameraDepthTexture, float4(uv, 0, 0)); // [0,1]
                if(!(0 < raw && raw < 1)) { discard; }
                // Rebuild position in VS from screenspace.
                // Craft a far plane CS position using OpenGL depth format [near, far]=[-1, 1]
                float far_plane_depth = _ProjectionParams.z;
                float4 pixel_at_far_plane_cs = float4(uv * 2.0 - 1.0, 1, 1) * far_plane_depth;
                // Thus we can use the OpenGL format unity_CameraInvProjection. No choice as unity_MatrixInvP is not available.
                float3 pixel_at_far_plane_vs = mul(unity_CameraInvProjection, pixel_at_far_plane_cs).xyz;
                return pixel_at_far_plane_vs * Linear01Depth(raw);
            }

            ENDCG
        }
    }
}
