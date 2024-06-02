// Overlay at optical infinity (reflecting sight), with crosshair, rangefinder distance, and worldspace compass.
// Attached to a flat surface with uniform UVs (like a quad), it will orient itself with the tangent space.
// Can be adapted to use object space if necessary.
Shader "Lereldarion/Overlay/SpatialHUD" {
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
                nointerpolation float3 rotating_uv_x_os : ROTATING_UV_X;
                nointerpolation float3 rotating_uv_y_os : ROTATING_UV_Y;

                // Unit vectors that stay aligned to the vertical direction
                nointerpolation float3 aligned_uv_x_os : ALIGNED_UV_X;
                nointerpolation float3 aligned_uv_y_os : ALIGNED_UV_Y;

                nointerpolation uint4 range_digits : RANGE_DIGITS;

                nointerpolation uint4 world_x_digits : WORLD_X_DIGITS;
                nointerpolation uint4 world_y_digits : WORLD_Y_DIGITS;
                nointerpolation uint4 world_z_digits : WORLD_Z_DIGITS;

                nointerpolation float azimuth_radiants : AZIMUTH;
                nointerpolation float elevation_radiants : ELEVATION;

                UNITY_VERTEX_OUTPUT_STEREO
            };

            // Macro required: https://issuetracker.unity3d.com/issues/gearvr-singlepassstereo-image-effects-are-not-rendering-properly
            // Requires a source of dynamic light to be populated https://github.com/netri/Neitri-Unity-Shaders#types ; sad...
            UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);

            static const float pi = 3.14159265359;

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
                const float3 up_direction_os = UnityWorldToObjectDir(float3(0, 1, 0));
                const float3 horizontal_tangent = normalize(cross(i.normal_os, up_direction_os));
                o.aligned_uv_x_os = horizontal_tangent * -1 /* again needed to mirror text correctly */;
                o.aligned_uv_y_os = cross(horizontal_tangent, i.normal_os);
                
                // World azimuth and elevation of the surface forward normal
                const float3 east_os = UnityWorldToObjectDir(float3(1, 0, 0));
                const float3 north_os = UnityWorldToObjectDir(float3(0, 0, 1));
                const float angular_dist_to_north_0_pi = acos(dot(horizontal_tangent, east_os));
                o.azimuth_radiants = pi - angular_dist_to_north_0_pi * sign(dot(horizontal_tangent, north_os)); // 0 at north, pi/2 east, pi south, 3pi/2 west
                const float angular_dist_to_up_0_pi = acos(dot(i.normal_os, up_direction_os));
                o.elevation_radiants = pi/2 - angular_dist_to_up_0_pi; // -pi/2 when looking at the bottom, pi/2 at the top

                // Compute depth from the depth texture.
                // Sample at the crosshair center, which means aligned with the normal of the quad.
                // Always use data from the first eye to have matching ranges between eyes.
                #if UNITY_SINGLE_PASS_STEREO
                const float3 camera_pos_ws = unity_StereoWorldSpaceCameraPos[0];
                const float4x4 matrix_vp = unity_StereoMatrixVP[0];
                #else
                const float3 camera_pos_ws = _WorldSpaceCameraPos;
                const float4x4 matrix_vp = UNITY_MATRIX_VP;
                #endif
                const float3 sight_normal_ws = UnityObjectToWorldDir(i.normal_os);
                const float3 sample_point_ws = camera_pos_ws + sight_normal_ws;
                const float4 sample_point_cs = mul(matrix_vp, float4(sample_point_ws, 1)); // UnityWorldToClipPos()
                float4 screen_pos = ComputeNonStereoScreenPos(sample_point_cs);
                #if UNITY_SINGLE_PASS_STEREO
                // o.xy = TransformStereoScreenSpaceTex(o.xy, pos.w);
                screen_pos.xy = screen_pos.xy * unity_StereoScaleOffset[0].xy + unity_StereoScaleOffset[0].zw * screen_pos.w;
                #endif
                const float depth_texture_value = SAMPLE_DEPTH_TEXTURE_LOD(_CameraDepthTexture, float4(screen_pos.xy / screen_pos.w, 0, 4 /* mipmap level */));
                const float range_ws = length(sight_normal_ws) * LinearEyeDepth(depth_texture_value) / sample_point_cs.w;

                // Pre compute digits to print for range and world position
                const float4 printed_values = float4(
                    range_ws,
                    abs(camera_pos_ws) // sign handled in fragment
                );
                uint4 int_values = clamp((uint4) printed_values, 0, 9999);
                const uint4 digit_1 = int_values % 10; int_values = int_values / 10;
                const uint4 digit_10 = int_values % 10; int_values = int_values / 10;
                const uint4 digit_100 = int_values % 10; int_values = int_values / 10;
                const uint4 digit_1000 = int_values;
                o.range_digits   = uint4(digit_1000[0], digit_100[0], digit_10[0], digit_1[0]);
                o.world_x_digits = uint4(digit_1000[1], digit_100[1], digit_10[1], digit_1[1]);
                o.world_y_digits = uint4(digit_1000[2], digit_100[2], digit_10[2], digit_1[2]);
                o.world_z_digits = uint4(digit_1000[3], digit_100[3], digit_10[3], digit_1[3]); 

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
                // https://learnopengl.com/In-Practice/Text-Rendering
                // all sizes in px with respect to the texture
                float2 offset;
                float2 size;
                // offset of top left corner in px when placing the rect
                float2 horizontal_bearing;
                // offset for the next character origin
                float advance;
            };
            static const GlyphDefinition glyph_definition_table[13] = {
                { float2( 10,  10), float2(44, 64), float2(3.51, 62.84 - 64), 50.0 }, // 0
                { float2(135, 173), float2(40, 62), float2(6.85, 61.92 - 62), 50.0 }, // 1
                { float2(138,  10), float2(42, 63), float2(4.53, 62.84 - 63), 50.0 }, // 2
                { float2( 10,  93), float2(44, 64), float2(3.42, 62.84 - 64), 50.0 }, // 3
                { float2( 73,  10), float2(46, 62), float2(2.06, 61.92 - 62), 50.0 }, // 4
                { float2( 73,  91), float2(44, 63), float2(3.60, 61.92 - 63), 50.0 }, // 5
                { float2( 73, 173), float2(43, 64), float2(4.58, 62.84 - 64), 50.0 }, // 6
                { float2(136,  92), float2(42, 62), float2(4.61, 61.92 - 62), 50.0 }, // 7
                { float2( 10, 176), float2(44, 64), float2(3.91, 62.84 - 64), 50.0 }, // 8
                { float2(199,  10), float2(42, 64), float2(4.22, 62.84 - 64), 50.0 }, // 9
                { float2(197,  93), float2(45, 45), float2(4.39, 51.94 - 45), 52.6 }, // +
                { float2(197, 157), float2(22,  8), float2(4.00, 27.42 -  8), 30.0 }, // -
                { float2(194, 184), float2( 9, 10), float2(8.22,  9.63 - 10), 25.0 }, // .
            };
            static const float glyph_texture_resolution = 256; // resolution at which definition values have been computed
            static const float2 glyph_max_box_size = float2(50.1, 70); // Used for UI spacing, chosen by hand from above data
            

            // A glyph renderer checks if each added character bounds contain the current pixel, and updates glyph texture uv when it does.
            // At the end we can sample only once the texture to get the SDF value.
            // This value is the value of the last character touching the current pixel for this renderer.
            // Pros : only one texture sample.
            // Cons : no overlap between characters of a renderer (but you can have overlaps by merging SDFs from 2 renderers).
            struct GlyphRenderer {
                // Accumulator : which pixels to sample in the glyph table for the current pixel
                float2 glyph_texture_coord;

                void add(GlyphDefinition glyph, float2 pixel_uv, float2 origin_uv, float scale) {
                    float2 glyph_drawing_space = (pixel_uv - origin_uv) / scale;
                    float2 glyph_box_coord = glyph_drawing_space - glyph.horizontal_bearing;
                    bool within_glyph_box = all(0 <= glyph_box_coord && glyph_box_coord <= glyph.size);
                    if(within_glyph_box) {
                        glyph_texture_coord = glyph_box_coord + glyph.offset;
                    }
                }

                float2 add_left(uint glyph_id, float2 pixel_uv, float2 origin_uv, float scale) {
                    GlyphDefinition glyph = glyph_definition_table[glyph_id];
                    origin_uv = origin_uv - float2(glyph.advance * scale, 0);
                    add(glyph, pixel_uv, origin_uv, scale);
                    return origin_uv;
                }

                float2 add_right(uint glyph_id, float2 pixel_uv, float2 origin_uv, float scale) {
                    GlyphDefinition glyph = glyph_definition_table[glyph_id];
                    add(glyph, pixel_uv, origin_uv, scale);
                    return origin_uv + float2(glyph.advance * scale, 0);
                }

                float sdf(float thickness) {
                    const float2 glyph_texture_uv = glyph_texture_coord / glyph_texture_resolution;
                    // Force mipmap 0, as we have artefacts with auto mipmap (derivatives are propably noisy). Texture is small anyway.
                    const float tex_sdf = _Glyph_Texture_SDF.SampleLevel(sampler_Glyph_Texture_SDF, glyph_texture_uv, 0);
                    // 1 interior, 0 exterior
                    return (1 - tex_sdf) - thickness;
                }
            };
            GlyphRenderer create_glyph_renderer() {
                GlyphRenderer r;
                // Usually the corners are outside glyphs
                r.glyph_texture_coord = float2(0, 0);
                return r;
            }

            ////////////////////////////////////////////////////////////////////////////////////
            // Range

            void draw_range_counter(float2 uv, uint4 digits, inout GlyphRenderer renderer) {
                const float scale = 0.0004;
                float2 origin = float2(0, -0.07);
                origin = renderer.add_right(digits[0], uv, origin, scale);
                origin = renderer.add_right(digits[1], uv, origin, scale);
                origin = renderer.add_right(digits[2], uv, origin, scale);
                origin = renderer.add_right(digits[3], uv, origin, scale);
            }

            ////////////////////////////////////////////////////////////////////////////////////
            // World position block

            void draw_world_position(float2 uv, float2 origin, float scale, bool negative, uint4 digits, inout GlyphRenderer renderer) {
                origin = renderer.add_left(digits[3], uv, origin, scale);
                origin = renderer.add_left(digits[2], uv, origin, scale);
                origin = renderer.add_left(digits[1], uv, origin, scale);
                origin = renderer.add_left(digits[0], uv, origin, scale);
                UNITY_FLATTEN if(negative) {
                    renderer.add_left(11 /* '-' */, uv, origin, scale);
                }
            }

            void draw_world_position_block(float2 uv, v2f i, inout GlyphRenderer renderer) {
                #if UNITY_SINGLE_PASS_STEREO // Consistent position. Digits are computed in vertex, but sign is cheap to do there.
                const float3 camera_pos_ws = unity_StereoWorldSpaceCameraPos[0];
                #else
                const float3 camera_pos_ws = _WorldSpaceCameraPos;
                #endif
                const float scale = 0.0003;
                const float2 origin = float2(-0.1, -0.05);

                // Draw left and down from origin. Compute a bounding box to condition this rendering with a real branch.
                const float2 v_offset = -float2(0, glyph_max_box_size.y) * scale;
                const float2 h_offset = -float2(glyph_max_box_size.x, 0) * scale;
                const float2 bounding_box_bottom_left = origin + 4 * v_offset + 5 * h_offset;
                if (all(bounding_box_bottom_left < uv && uv < origin)) {
                    draw_world_position(uv, origin + 1 * v_offset, scale, camera_pos_ws.x < 0, i.world_x_digits, renderer);
                    draw_world_position(uv, origin + 2 * v_offset, scale, camera_pos_ws.y < 0, i.world_y_digits, renderer);
                    draw_world_position(uv, origin + 3 * v_offset, scale, camera_pos_ws.z < 0, i.world_z_digits, renderer);
                }
            }

            ////////////////////////////////////////////////////////////////////////////////////
            // Sight

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

            ////////////////////////////////////////////////////////////////////////////////////
            // Compass

            float3 closest_step_positioning(float angle_rad, float step_interval_deg) {
                const float step_interval_rad = step_interval_deg / 180. * pi;
                const float unit_coordinate = angle_rad / step_interval_rad;
                // Positionning in "unit" coordinates
                const float closest_step = round(unit_coordinate);
                const float angle_difference_to_closest_step = unit_coordinate - closest_step;
                const float distance_to_closest_step = abs(angle_difference_to_closest_step); // [-0.5, 0.5]
                return float3(closest_step, angle_difference_to_closest_step, distance_to_closest_step) * step_interval_rad;
            }

            float interval_1d_centered_sdf(float x, float center, float radius) {
                return abs(x - center) - radius;
            }

            float interval_1d_sdf(float x, float from, float to) {
                return interval_1d_centered_sdf(x, (from + to) / 2., (to - from) / 2.);
            }

            float glsl_mod(float x, float y) {
                return x - y * floor(x / y);
            }

            float elevation_display_sdf(float2 uv, float elevation_at_0, inout GlyphRenderer renderer) {
                const float tick_start_x = 0.2;
                const float tick_length = 0.01;
                const float legend_start_x = tick_start_x + tick_length * 2.3;
                const float glyph_scale = 0.0003;
                
                // UVs are sin angle from normal ~ angle for center, in radiants
                const float pixel_elevation = elevation_at_0 + uv.y;

                // Tick marks : vertical column & distance to nearest tick using round(y)
                const float3 ticks_1_deg = closest_step_positioning(pixel_elevation, 1.);
                const float3 ticks_10_deg = closest_step_positioning(pixel_elevation, 10.);
                const float tick_1_sdf = max(interval_1d_sdf(uv.x, tick_start_x, tick_start_x + tick_length), ticks_1_deg.z);
                const float tick_10_sdf = max(interval_1d_sdf(uv.x, tick_start_x, tick_start_x + tick_length * 2), ticks_10_deg.z);
                const float window_sdf = interval_1d_centered_sdf(uv.y, 0., 11. / 180. * pi);
                const float ticks_sdf = max(min(tick_1_sdf, tick_10_sdf), window_sdf);

                // Display 2 digit degree count
                if(window_sdf < 0 && interval_1d_sdf(uv.x, legend_start_x, legend_start_x + 3 * glyph_scale * glyph_max_box_size.x) < 0) {
                    const float legend_elevation_rad = ticks_10_deg.x;
                    float2 legend_origin = float2(legend_start_x, legend_elevation_rad - elevation_at_0) + glyph_scale * glyph_max_box_size * float2(0, -0.35);

                    uint digit_10 = (uint) round(abs(legend_elevation_rad) * 18. / pi); // [-9, 9]

                    UNITY_FLATTEN if(legend_elevation_rad < 0) {
                        legend_origin = renderer.add_right(11 /* '-' */, uv, legend_origin, glyph_scale);
                    } else {
                        legend_origin.x += glyph_definition_table[11].advance * glyph_scale;
                    }

                    legend_origin = renderer.add_right(digit_10, uv, legend_origin, glyph_scale);
                    renderer.add_right(0, uv, legend_origin, glyph_scale);
                }          
                return ticks_sdf;
            }

            float azimuth_display_sdf(float2 uv, float azimuth_at_0, inout GlyphRenderer renderer) {
                const float tick_start_y = 0.2;
                const float tick_length = 0.01;
                const float legend_start_y = tick_start_y + tick_length * 2.1;
                const float glyph_scale = 0.0003;
                
                // UVs are sin angle from normal ~ angle for center, in radiants
                const float pixel_azimuth = azimuth_at_0 + uv.x;

                // Tick marks : vertical column & distance to nearest tick using round(y)
                const float3 ticks_1_deg = closest_step_positioning(pixel_azimuth, 1.);
                const float3 ticks_10_deg = closest_step_positioning(pixel_azimuth, 10.);
                const float tick_1_sdf = max(interval_1d_sdf(uv.y, tick_start_y, tick_start_y + tick_length), ticks_1_deg.z);
                const float tick_10_sdf = max(interval_1d_sdf(uv.y, tick_start_y, tick_start_y + tick_length * 2), ticks_10_deg.z);
                const float window_sdf = interval_1d_centered_sdf(uv.x, 0., 15. / 180. * pi);
                const float ticks_sdf = max(min(tick_1_sdf, tick_10_sdf), window_sdf);

                // Display 2 digit degree count
                if(window_sdf < 0 && interval_1d_sdf(uv.y, legend_start_y, legend_start_y + glyph_scale * glyph_max_box_size.y) < 0) {
                    const float legend_azimuth_rad = ticks_10_deg.x;
                    float2 legend_origin = float2(legend_azimuth_rad - azimuth_at_0, legend_start_y) + glyph_scale * glyph_max_box_size * float2(-1.5, 0.1);

                    const float legend_azimuth_10deg = legend_azimuth_rad * 18. / pi;
                    uint n = (uint) glsl_mod(legend_azimuth_10deg, 36.); // [0, 35]
                    uint digit_10 = n % 10;
                    uint digit_100 = n / 10;

                    legend_origin = renderer.add_right(digit_100, uv, legend_origin, glyph_scale);
                    legend_origin = renderer.add_right(digit_10, uv, legend_origin, glyph_scale);
                    renderer.add_right(0, uv, legend_origin, glyph_scale);
                }          
                return ticks_sdf;
            }

            ////////////////////////////////////////////////////////////////////////////////////
            // Composition

            uniform fixed4 _Color;

            fixed4 frag (v2f i) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // i.{aligned/rotating}_uv_{x/y}_os are vectors in a plane facing the view.
                // We want a measure of angle to view dir ~ sin angle to view dir = cos angle to these plane vectors.
                const float3 view_ray = normalize(i.eye_to_geometry_os);
                const float2 rotating_uv = float2(dot(view_ray, i.rotating_uv_x_os), dot(view_ray, i.rotating_uv_y_os));
                const float2 aligned_uv = float2(dot(view_ray, i.aligned_uv_x_os), dot(view_ray, i.aligned_uv_y_os));

                float sdf = 1000 * sight_pattern_sdf(rotating_uv); // Need high scale due to uv units

                GlyphRenderer renderer = create_glyph_renderer();
                draw_range_counter(rotating_uv, i.range_digits, renderer);
                draw_world_position_block(rotating_uv, i, renderer);
                sdf = min(sdf, 1000 * elevation_display_sdf(aligned_uv, i.elevation_radiants, renderer));
                sdf = min(sdf, 1000 * azimuth_display_sdf(aligned_uv, i.azimuth_radiants, renderer));
                sdf = min(sdf, 3 * renderer.sdf(0.15)); // Scale for sharpness

                // We have few pixels, so make a smooth border FIXME improve consistency
                const float positive_distance = max(0, sdf);
                const float fade = 1. - positive_distance * positive_distance;
                if (fade <= 0) {
                    discard;
                }
                return _Color * fade;
            }

            ENDCG
        }
    }
}
