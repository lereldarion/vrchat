
Shader "Lereldarion/Overlay/ReflectorSight" {
    Properties {
        [HDR] _Color("Sight emissive color", Color) = (0, 1, 0, 1)
        _SDF_Numbers ("SDF Number texture", 2D) = "white"
    }
    SubShader {
        Tags {
            "Queue" = "Overlay"
            "RenderType" = "Overlay"
            "VRCFallback" = "Hidden"
        }
        
        Cull Off
        Blend One One
        ZWrite Off

        Pass {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            
            #include "UnityCG.cginc"
            #pragma target 5.0

            struct appdata {
                float4 position_os : POSITION;
                float3 normal_os : NORMAL;
                float4 tangent_os : TANGENT;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct v2f {
                float4 position_cs : SV_POSITION;

                float3 uvx_os : UVX;
                float3 uvy_os : UVY;
                float3 eye_to_geometry_os : EYE_TO_GEOMETRY_OS;

                uint4 range_digits : RANGE_DIGITS;

                UNITY_VERTEX_OUTPUT_STEREO
            };

            // Macro required: https://issuetracker.unity3d.com/issues/gearvr-singlepassstereo-image-effects-are-not-rendering-properly
            // Requires a source of dynamic light to be populated https://github.com/netri/Neitri-Unity-Shaders#types ; sad...
            UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);

            float3 centered_camera_ws() {
                #if UNITY_SINGLE_PASS_STEREO
                return 0.5 * (unity_StereoWorldSpaceCameraPos[0] + unity_StereoWorldSpaceCameraPos[1]);
                #else
                return _WorldSpaceCameraPos;
                #endif
            }

            v2f vert (appdata i) {
                UNITY_SETUP_INSTANCE_ID(i);
                v2f o;
                o.position_cs = UnityObjectToClipPos(i.position_os);
                
                o.eye_to_geometry_os = -ObjSpaceViewDir(i.position_os);
                if(dot(i.normal_os, o.eye_to_geometry_os) < 0) {
                    // Always use a forward looking orientation
                    i.normal_os = -i.normal_os;
                    i.tangent_os.xyz = -i.tangent_os.xyz;
                }

                o.uvx_os = i.tangent_os;
                o.uvy_os = normalize(cross(i.tangent_os, i.normal_os) * i.tangent_os.w * -1);
                
                // Compute depth from the depth texture.
                // Sample at the crosshair center, which means aligned with the normal of the quad.
                float3 sight_normal_ws = UnityObjectToWorldDir(i.normal_os);
                float3 sample_point_ws = centered_camera_ws() + sight_normal_ws;
                float4 sample_point_cs = UnityWorldToClipPos(sample_point_ws);
                float4 screen_pos = ComputeScreenPos(sample_point_cs);
                float depth_texture_value = SAMPLE_DEPTH_TEXTURE_LOD(_CameraDepthTexture, float4(screen_pos.xy / screen_pos.w, 0, 4 /* mipmap level */));
                if(depth_texture_value == 0) {
                    o.range_digits = uint4(9, 9, 9, 9);
                } else {
                    float range = length(sight_normal_ws) * LinearEyeDepth(depth_texture_value) / sample_point_cs.w;
                    
                    // Decompose in digits
                    uint i = clamp((uint) range, 0, 9999);
                    uint digit0 = i % 10; i = i / 10;
                    uint digit1 = i % 10; i = i / 10;
                    uint digit2 = i % 10; i = i / 10;
                    uint digit3 = i;
                    o.range_digits = uint4(digit0, digit1, digit2, digit3);
                }
                
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                return o;
            }

            float sight_pattern_sdf(float2 uv) {
                // create the sight pattern based on 0-centered "uv"
                // Distance is always positive, with no "interior" negative values. Skybox uv units.
                // Relies on the final fade for thickness.

                const float circle_radius = 0.04;
                float circle_sdf = abs(length(uv) - circle_radius);

                uv = abs(uv); // look in upper right quadrant, all symmetric anyway
                uv = float2(max(uv.x, uv.y), min(uv.x, uv.y)); // lower triangle of the quadrant
                float2 closest_segment_point = float2(clamp(uv.x, 0.01, 0.07), 0);
                float cross_sdf = distance(uv, closest_segment_point);

                const float thickness_bias = 0.0;
                return min(circle_sdf, cross_sdf) - thickness_bias;
            }

            // SDF texture containing glyphs for numbers, and offsets in the texture.
            // Generated using TextMeshPro and extracted afterwards (using screenshot of preview, as "Extract Atlas" option and similar did not work).
            UNITY_DECLARE_TEX2D(_SDF_Numbers);
            static const float4 glyph_offset_size[11] = {
                float4( 11,  11, 44, 64) / 256, // 0
                float4(203,  95, 40, 62) / 256, // 1
                float4(139, 179, 42, 63) / 256, // 2
                float4( 11,  96, 44, 64) / 256, // 3
                float4( 76,  11, 46, 62) / 256, // 4
                float4(143,  11, 44, 63) / 256, // 5
                float4( 76,  94, 43, 64) / 256, // 6
                float4(140,  95, 42, 62) / 256, // 7
                float4( 11, 181, 44, 64) / 256, // 8
                float4( 76, 179, 42, 64) / 256, // 9
                float4(208,  11,  9, 10) / 256, // .
            };

            float digit_glyph_sdf(float2 uv, uint digit, float2 pos, float scale) {
                float4 texture_rect = glyph_offset_size[digit];
                float2 texture_offset = texture_rect.xy;
                float2 texture_size = texture_rect.zw;

                uv.x = -uv.x; // correct mirroring ; maybe fix when applied on other quads
                
                uv = (uv - pos) / scale;
                bool within_glyph = all(0 < uv && uv < texture_size);

                float2 texture_uv = uv + texture_offset;
                float tex_sdf = UNITY_SAMPLE_TEX2D(_SDF_Numbers, texture_uv).r;
                // 0.5 should be the edge with dist = 0 ; > 0.5 is interior, < 0.5 is exterior
                float sdf = within_glyph ? 0.5 - tex_sdf : 0.5;

                return sdf + 0.05; // bias to control thickness
            }

            float range_counter_sdf(float2 uv, uint4 range_digits) {
                const float scale = 0.1;
                const float2 pos = float2(0.005, -0.07);
                const float2 increment = float2(0.17, 0) * scale;
                // TODO rotation matrix
                float d = digit_glyph_sdf(uv, range_digits[3], pos, scale);
                d = min(d, digit_glyph_sdf(uv, range_digits[2], pos + increment, scale));
                d = min(d, digit_glyph_sdf(uv, range_digits[1], pos + 2 * increment, scale));
                d = min(d, digit_glyph_sdf(uv, range_digits[0], pos + 3 * increment, scale));
                return d;
            }

            uniform fixed4 _Color;

            fixed4 frag (v2f i) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                float3 view_ray = normalize(i.eye_to_geometry_os);
                float2 skybox_uv = float2(dot(view_ray, i.uvx_os), dot(view_ray, i.uvy_os));

                float sdf = 1000 * sight_pattern_sdf(skybox_uv); // Need high scale due to skyvbox uv units
                sdf = min(sdf, 3 * range_counter_sdf(skybox_uv, i.range_digits)); // Scale for sharpness

                // We have few pixels, so make a smooth border
                float positive_distance = max(0, sdf);
                float fade = 1. - positive_distance * positive_distance;
                if (fade <= 0) {
                    discard;
                }
                return _Color * fade;
            }

            ENDCG
        }
    }
}
