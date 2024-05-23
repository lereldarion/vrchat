// Overlay at optical infinity (reflecting sight), with crosshair, rangefinder distance.
// Attached to a flat surface with uniform UVs (like a quad)
Shader "Lereldarion/Overlay/ReflectorSight" {
    Properties {
        [HDR] _Color("Sight emissive color", Color) = (0, 1, 0, 1)
        _Glyph_Texture_SDF ("Texture with SDF glyphs", 2D) = "white"
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
                
                float3 eye_to_geometry_os : EYE_TO_GEOMETRY_OS;

                // Unit vectors rotating with the overlay surface
                float3 rotating_uv_x_os : ROTATING_UV_X;
                float3 rotating_uv_y_os : ROTATING_UV_Y;

                // Unit vectors that stay aligned to the vertical direction
                float3 aligned_uv_x_os : ALIGNED_UV_X;
                float3 aligned_uv_y_os : ALIGNED_UV_Y;

                uint4 range_digits : RANGE_DIGITS;

                UNITY_VERTEX_OUTPUT_STEREO
            };

            // Macro required: https://issuetracker.unity3d.com/issues/gearvr-singlepassstereo-image-effects-are-not-rendering-properly
            // Requires a source of dynamic light to be populated https://github.com/netri/Neitri-Unity-Shaders#types ; sad...
            UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);

            v2f vert (appdata i) {
                UNITY_SETUP_INSTANCE_ID(i);
                v2f o;
                o.position_cs = UnityObjectToClipPos(i.position_os);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                
                o.eye_to_geometry_os = -ObjSpaceViewDir(i.position_os);

                // Always use a forward looking orientation
                if(dot(i.normal_os, o.eye_to_geometry_os) < 0) {
                    i.normal_os = -i.normal_os;
                    i.tangent_os.xyz = -i.tangent_os.xyz;
                }

                // Use tangent space to follow quad rotations
                o.rotating_uv_x_os = i.tangent_os.xyz * -1 /* needed to mirror text correctly */;
                o.rotating_uv_y_os = normalize(cross(i.tangent_os, i.normal_os) * i.tangent_os.w * -1);

                // Similar skybox coordinate system but y stays aligned to worldspace vertical.
                float3 up_direction_os = UnityWorldToObjectDir(float3(0, 1, 0)); // +y
                float3 horizontal_tangent = normalize(cross(i.normal_os, up_direction_os));
                o.aligned_uv_x_os = horizontal_tangent * -1 /* again needed to mirror text correctly */;
                o.aligned_uv_y_os = cross(horizontal_tangent, i.normal_os);
                
                // Compute depth from the depth texture.
                // Sample at the crosshair center, which means aligned with the normal of the quad.
                // Always use data from the first eye to have matching ranges between eyes.
                #if UNITY_SINGLE_PASS_STEREO
                float3 camera_pos_ws = unity_StereoWorldSpaceCameraPos[0];
                float4x4 matrix_vp = unity_StereoMatrixVP[0];
                #else
                float3 camera_pos_ws = _WorldSpaceCameraPos;
                float4x4 matrix_vp = UNITY_MATRIX_VP;
                #endif
                float3 sight_normal_ws = UnityObjectToWorldDir(i.normal_os);
                float3 sample_point_ws = camera_pos_ws + sight_normal_ws;
                float4 sample_point_cs = mul(matrix_vp, float4(sample_point_ws, 1)); // UnityWorldToClipPos()
                float4 screen_pos = ComputeNonStereoScreenPos(sample_point_cs);
                #if UNITY_SINGLE_PASS_STEREO
                // o.xy = TransformStereoScreenSpaceTex(o.xy, pos.w);
                screen_pos.xy = screen_pos.xy * unity_StereoScaleOffset[0].xy + unity_StereoScaleOffset[0].zw * screen_pos.w;
                #endif
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
                
                return o;
            }

            ////////////////////////////////////////////////////////////////////////////////////
            // Glyph SDF system.
            
            // SDF texture containing glyphs, and metadata for each glyph.
            // Texture is generated using TextMeshPro and extracted afterwards (using screenshot of preview, as "Extract Atlas" option did not work).
            Texture2D<float> _Glyph_Texture_SDF;
            SamplerState sampler_Glyph_Texture_SDF;
            // Metadata copied by hand for now.
            struct GlyphDefinition {
                // all sizes in px with respect to the texture
                float2 offset;
                float2 size;
                // offset of top left corner in px when placing the rect
                float2 horizontal_bearing;
                // offset for the next character origin
                float advance;
            };
            static const GlyphDefinition glyph_definition_table[13] = {
                { float2( 10,  10), float2(44, 64), float2(3.51, 62.84), 50.0 }, // 0
                { float2(135, 173), float2(40, 62), float2(6.85, 61.92), 50.0 }, // 1
                { float2(138,  10), float2(42, 63), float2(4.53, 62.84), 50.0 }, // 2
                { float2( 10,  93), float2(44, 64), float2(3.42, 62.84), 50.0 }, // 3
                { float2( 73,  10), float2(46, 62), float2(2.06, 61.92), 50.0 }, // 4
                { float2( 73,  91), float2(44, 63), float2(3.60, 61.92), 50.0 }, // 5
                { float2( 73, 173), float2(43, 64), float2(4.58, 62.84), 50.0 }, // 6
                { float2(136,  92), float2(42, 62), float2(4.61, 61.92), 50.0 }, // 7
                { float2( 10, 176), float2(44, 64), float2(3.91, 62.84), 50.0 }, // 8
                { float2(199,  10), float2(42, 64), float2(4.22, 62.84), 50.0 }, // 9
                { float2(197,  93), float2(45, 45), float2(4.39, 51.94), 52.6 }, // +
                { float2(197, 157), float2(22,  8), float2(4.00, 27.42), 30.0 }, // -
                { float2(194, 184), float2( 9, 10), float2(8.22,  9.63), 25.0 }, // .
            };

            // A glyph renderer checks if each added character bounds contain the current pixel, and updates glyph texture uv when it does.
            // At the end we can sample only once the texture to get the SDF value.
            // This value is the value of the last character touching the current pixel for this renderer.
            // Pros : only one texture sample.
            // Cons : no overlap between characters of a renderer (but you can have overlaps by merging SDFs from 2 renderers).
            struct GlyphRenderer {
                // Accumulator : which pixels to sample in the glyph table for the current pixel
                float2 glyph_tex_uv;

                // FIXME proper char sequence rendering using all metadata. return next origin with advance.
                void add(uint glyph_id, float2 uv, float2 pos, float scale) {
                    GlyphDefinition glyph = glyph_definition_table[glyph_id];
                    float2 texture_offset = glyph.offset / 256.;
                    float2 texture_size = glyph.size / 256.;
                    
                    uv = (uv - pos) / scale;
                    bool within_glyph = all(0 < uv && uv < texture_size);
                    if(within_glyph) {
                        glyph_tex_uv = uv + texture_offset;
                    }
                }

                float sdf(float thickness) {
                    // Force mipmap 0, as we have artefacts with auto mipmap (derivatives are propably noisy).
                    // Texture is small anyway.
                    float tex_sdf = _Glyph_Texture_SDF.SampleLevel(sampler_Glyph_Texture_SDF, glyph_tex_uv, 0);
                    // 1 interior, 0 exterior
                    return (1 - tex_sdf) - thickness;
                }
            };
            GlyphRenderer create_glyph_renderer() {
                GlyphRenderer r;
                r.glyph_tex_uv = float2(0, 0); // Usually the corners are outside glyphs
                return r;
            }

            ////////////////////////////////////////////////////////////////////////////////////
            // UI

            float range_counter_sdf(float2 uv, uint4 range_digits) {
                const float scale = 0.1;
                const float2 pos = float2(0.005, -0.07);
                const float2 increment = float2(0.175, 0) * scale;
                GlyphRenderer renderer = create_glyph_renderer();
                renderer.add(range_digits[3], uv, pos, scale);
                renderer.add(range_digits[2], uv, pos + increment, scale);
                renderer.add(range_digits[1], uv, pos + 2 * increment, scale);
                renderer.add(range_digits[0], uv, pos + 3 * increment, scale);
                return renderer.sdf(0.15);
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

            uniform fixed4 _Color;

            fixed4 frag (v2f i) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                float3 view_ray = normalize(i.eye_to_geometry_os);
                float2 rotating_uv = float2(dot(view_ray, i.rotating_uv_x_os), dot(view_ray, i.rotating_uv_y_os));
                float2 aligned_uv = float2(dot(view_ray, i.aligned_uv_x_os), dot(view_ray, i.aligned_uv_y_os));

                float sdf = 1000 * sight_pattern_sdf(rotating_uv); // Need high scale due to uv units
                sdf = min(sdf, 3 * range_counter_sdf(rotating_uv, i.range_digits)); // Scale for sharpness

                // We have few pixels, so make a smooth border FIXME improve consistency
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
