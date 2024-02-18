// Render blocs as raymarched snowflakes
// Adapted from https://www.shadertoy.com/view/Xsd3zf
//
// Has some Forward Rendering lighting (PBR-ish).
// No add pass or shadow casting to avoid doing marching more than once.
// Transparency is faked using skybox ; this should reduce marching calls and overdraw.

Shader "Lereldarion/Replicator/Snowflake" {
Properties {
    _MainTex("Fallback", 2D) = "white" { }

    // Raymarching config
    _Raymarching_Zoom("Zoom", Range(0.1, 4.)) = 3
    _Raymarching_Space_Scale("Snowflake scale", Range(0.1, 10)) = 2
    _Raymarching_Geometry_Radius_Scale("Support Geometry Radius Scale", Range(0.4, 1)) = 0.6 // At higher zoom the flake does not occupy all of the radius-based geometry
    [NoScaleOffset, NonModifiableTextureData] _Raymarching_NoiseTex("Noise texture", 2D) = "white" {}

    // Base animations
    _Replicator_Dislocation_Global("Dislocation Global (show, time, spatial_delay_factor, _)", Vector) = (1, 0, 0, 0)
    _Replicator_Dislocation_LeftArm("Dislocation LeftArm (show_upper_bound, animation_lower_bound, time, _)", Vector) = (1, 1, 0, 0)
    _Replicator_Dislocation_RightArm("Dislocation RightArm (show_upper_bound, animation_lower_bound, time, _)", Vector) = (1, 1, 0, 0)
    _Replicator_Dislocation_LeftLeg("Dislocation LeftLeg (show_upper_bound, animation_lower_bound, time, _)", Vector) = (1, 1, 0, 0)

    [ToggleUI] _Replicator_AudioLink("Enable AudioLink", Float) = 1
    [ToggleUI] _Replicator_DebugLOD("Debug LOD levels (R=0,G=1)", Float) = 0

    // Internal for lighting
    [NonModifiableTextureData] _DFG("DFG", 2D) = "white" {}
}

SubShader {
    Tags {
        "RenderType" = "TransparentCutout"
        "Queue" = "AlphaTest"
        "VRCFallback" = "ToonCutoutDoubleSided"
        "IgnoreProjector" = "True"
    }

    ZWrite On

    Pass {
        Tags {
            "LightMode" = "ForwardBase"
        }
        Name "ForwardBase"

        CGPROGRAM
        #pragma vertex Vertex
        #pragma geometry Geometry
        #pragma fragment Fragment
		#pragma multi_compile_instancing
        #pragma multi_compile_fog
		#pragma multi_compile_fwdbase
        // It seems than fwdbase is restricted to only DIRECTIONAL light.
        // Making the only light SPOT or POINT has no effect, even when the keywords are forced on (multi_compile_lightpass)

        // For avatar only
        #pragma skip_variants DYNAMICLIGHTMAP_ON LIGHTMAP_ON LIGHTMAP_SHADOW_MIXING DIRLIGHTMAP_COMBINED

        #define UNITY_INSTANCED_SH

        #include "UnityStandardUtils.cginc"
        #include "Lighting.cginc"
        #pragma target 5.0

        #include "Assets/Avatar/replicator_shader/baked_random_values.hlsl"

        ///////////////////////////////////////////////////

        struct VertexData {
            float4 vertex : POSITION;
            float2 uv0 : TEXCOORD0;
            float2 uv1 : TEXCOORD1;
            float2 uv2 : TEXCOORD2;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        struct FragmentData {
            float4 position_cs : SV_POSITION;
            float3 seed_data : SEED_DATA;

            float3 camera_ts : CAMERA_TS;
            float3 geometry_ts : VERTEX_TS;

            float4 ts_to_ws_0 : TS_TO_WS_0;
            float4 ts_to_ws_1 : TS_TO_WS_1;
            float4 ts_to_ws_2 : TS_TO_WS_2;

            float lod_level : LOD_LEVEL; // 0 or 1
            float ice_near_to_far : ICE_NEAR_TO_FAR;
            float audiolink_track : AUDIOLINK_TRACK;

            UNITY_FOG_COORDS(0)
            UNITY_VERTEX_INPUT_INSTANCE_ID
            UNITY_VERTEX_OUTPUT_STEREO
        };

        ///////////////////////////////////////////////////

        float length_sq (float2 v) { return dot(v, v); }
        float length_sq (float3 v) { return dot(v, v); }

        // Hash / noise
        static const float4 NC0 = float4(0, 157, 113, 270);
        static const float4 NC1 = float4(1, 158, 114, 271);

        // [0-1]
        float4 hash4 (float4 n) { return frac(sin(n) * 1399763.5453123); }

        // [0-1]
        float noise222 (float2 x, float2 y, float2 z) {
            float4 lx = x.xyxy * y.xxyy;
            float4 p = floor(lx);
            float4 f = frac(lx);
            f = f * f * (3.0 - 2.0 * f);
            float2 n = p.xz + p.yw * 157.0;
            float4 h = lerp(hash4(n.xxyy + NC0.xyxy), hash4(n.xxyy + NC1.xyxy), f.xxzz);
            return dot(lerp(h.xz, h.yw, f.yw), z);
        }
        UNITY_DECLARE_TEX2D(_Raymarching_NoiseTex);
        float noise2_tex(float2 p) {
            float2 uv = p * 0.3; // Scale from commented out code in shadertoy, required
            return UNITY_SAMPLE_TEX2D_LOD(_Raymarching_NoiseTex, uv * 0.25, 0).x; // shadertoy version used 64x64 tex, we use the 256x256 one here.
        }
        // [-0.5, 0.5]
        float noise2_centered (float2 p) {
            // Initially this was a LOD switch to 3 versions using the sin hash4 function, with various detail levels.
            // Removed LOD, and finally replaced noise impl with a noise texture ; the noise granularity is critical to the effect.
            // return noise222(p, float2(20.6, 100.6), float2(0.9, 0.1)) - 0.5;
            return noise2_tex(p) - 0.5;
        }

        // [0-1], used for seed
        float noise3 (float3 x) {
            float3 p = floor(x);
            float3 f = frac(x);
            f = f * f * (3.0 - 2.0 * f);
            float n = p.x + dot(p.yz, float2(157.0, 113.0));
            float4 s1 = lerp(hash4(n + NC0), hash4(n + NC1), f.xxxx);
            return lerp(lerp(s1.x, s1.y, f.y), lerp(s1.z, s1.w, f.y), f.z);
        }

        // Raymarching

        uniform float _Raymarching_Zoom;

        // Snowflake geometry : contained in a flat cylinder centered at 0, axis is z, radius on xy
        static const float3 snowflake_origin = float3(0, 0, 0);
        static const float3 snowflake_normal = float3(0, 0, 1);
        static const float snowflake_z_thickness = 0.0125; // z thickness on both sides
        static const float snowflake_xy_radius = 0.25; // above too much details

        struct MaybePoint {
            float3 position;
            bool valid;
        };
        // in snowflake space, ray = from camera to geometry normalized
        MaybePoint raycast_snowflake (const float3 camera, const float3 ray, const float3 seed_data) {
            const float zoom = _Raymarching_Zoom; // use this to change details. optimal 0.1 - 4.0.

            const float radius_sq = snowflake_xy_radius * snowflake_xy_radius;
            const float z_to_ray_factor = 1. / ray.z;
            const float thickness_z_toward_camera = snowflake_z_thickness * sign(camera.z);

            // Find intersect points ; negative values are discarded so they are also used as invalid markers
            float ray_t_front = -1;
            float ray_t_back = -2;

            // Cylinder faces ; see if plane intersect is within cylinder radius
            const float ray_t_front_plane = (thickness_z_toward_camera - camera.z) * z_to_ray_factor;
            const float3 front_plane_intersect = camera + ray * ray_t_front_plane;
            if (length_sq(front_plane_intersect.xy) < radius_sq) { ray_t_front = ray_t_front_plane; }

            const float ray_t_back_plane = (-thickness_z_toward_camera - camera.z) * z_to_ray_factor;
            const float3 back_plane_intersect = camera + ray * ray_t_back_plane;
            if (length_sq(back_plane_intersect.xy) < radius_sq) { ray_t_back = ray_t_back_plane; }

            MaybePoint result;
            result.valid = false;
            result.position = front_plane_intersect; // Start point of marching. Unconditional assignement because it must be set to something for ddx/y normals.
            
            // Cylinder barrel ; solve radius^2 = lenght_sq((camera + ray * t).xy)
            const float polynom_a = length_sq(ray.xy);
            const float polynom_b_div_2 = dot(camera.xy, ray.xy);
            const float polynom_c = length_sq(camera.xy) - radius_sq;
            const float discriminant_div_4 = polynom_b_div_2 * polynom_b_div_2 - polynom_a * polynom_c;
            if (discriminant_div_4 > 0) {
                const float sqrt_discriminant_div_2 = sqrt(discriminant_div_4);
                const float denominator_factor_x_2 = 1. / polynom_a;

                const float ray_t_front_barrel = denominator_factor_x_2 * (-polynom_b_div_2 - sqrt_discriminant_div_2);
                const float3 front_barrel_intersect = camera + ray * ray_t_front_barrel;
                if (abs(front_barrel_intersect.z) < snowflake_z_thickness) {
                    ray_t_front = ray_t_front_barrel;
                    result.position = front_barrel_intersect;
                }

                const float ray_t_back_barrel = denominator_factor_x_2 * (-polynom_b_div_2 + sqrt_discriminant_div_2);
                const float3 back_barrel_intersect = camera + ray * ray_t_back_barrel;
                if (abs(back_barrel_intersect.z) < snowflake_z_thickness) { ray_t_back = ray_t_back_barrel; }
            }

            const float ray_t_inside_snowflake = ray_t_back - ray_t_front;

            if (ray_t_front > 0 && ray_t_inside_snowflake > 0) {
                // Tuning of raymarching stepping. All 3 have visual impact.
                const int iterations = 15;
                float ds = ray_t_inside_snowflake / iterations;
                ds = lerp(snowflake_z_thickness, ds, 0.2); // 80% thickness
                ds = max(ds, 0.01); // Ensure performance by minimum step ?
                float3 step = ray * ds * 5.0; // [3, 10] tested and ok.

                for (int m = 0; m < iterations; m += 1) {
                    // Related to lobe construction. 
                    const float position_radius = length(result.position.xy);
                    float2 c3 = abs(result.position.xy / position_radius); // [0, 1]^2
                    if (c3.x > 0.5) {
                        c3 = abs(c3 * 0.5 + float2(-c3.y , c3.x) * 0.86602540 /*sin(pi/3) or cos(pi/6)*/); // tweak 2d field, probably creates the lobes with noise
                    }
                    // Iterate back and forth along ray. Not really marching, no SDF.
                    const float zoomed_radius = position_radius * zoom;
                    const float noise = noise2_centered(c3 * (pow(zoomed_radius, seed_data.z) + 0.1) + seed_data.xy); // [-0.5, 0.5]
                    const float up_biased_noise = lerp(noise, 1.0, abs(result.position.z * (0.2 / snowflake_z_thickness))); // blend with positive bias, up to 0.2 at |z|=thickness. 0.2 critical.
                    const float fill_factor = 0.35; // 0.25 starts making rings, nice up to 1, afterwards it becomes very skinny
                    const float displacement = 
                        max(
                            zoomed_radius - snowflake_xy_radius - 0.1, // [-snowflake_xy_radius - 0.1, (zoom-1) * snowflake_xy_radius - 0.1]. 0.1 kills outer circle sometimes
                            up_biased_noise // [-0.5, 0.6]
                        )
                        + (position_radius + c3.x * c3.x) * (fill_factor / snowflake_xy_radius) // position radius + lobe tweak, normalised to [0, 0.35]
                        - 0.7 * fill_factor;
                    if (displacement < 0 || abs(result.position.z) > snowflake_z_thickness + 0.01) {
                        break; // Stop if negative or out of bounds
                    }
                    result.position += step * displacement;
                    step *= 0.99;
                }
                if (abs(result.position.z) < snowflake_z_thickness + 0.01) {
                    result.valid = true;
                }
            }
            return result;
        }

        float3 make_seed_data(uint snowflake_id) {
            float random = baked_random_constants[snowflake_id % nb_baked_random_constants];
            float2 seed = float2(random, 1 + snowflake_id);
            float powr = noise3(float3(seed, 1) * 10.0) * 1.9 + 0.1;
            return float3(seed, powr);
        }

        ///////////////////////////////////////////////////

        uniform float4 _Replicator_Dislocation_Global;
        uniform float4 _Replicator_Dislocation_LeftArm;
        uniform float4 _Replicator_Dislocation_RightArm;
        uniform float4 _Replicator_Dislocation_LeftLeg;
        uniform bool _Replicator_AudioLink;

        float3x3 rotation_matrix(float3 axis, float angle_radians) {
            // https://en.wikipedia.org/wiki/Rotation_matrix#Rotation_matrix_from_axis_and_angle
            float3 u = normalize(axis);
            float C = cos(angle_radians);
            float S = sin(angle_radians);
            float t = 1 - C;
            float m00 = t * u.x * u.x + C;
            float m01 = t * u.x * u.y - S * u.z;
            float m02 = t * u.x * u.z + S * u.y;
            float m10 = t * u.x * u.y + S * u.z;
            float m11 = t * u.y * u.y + C;
            float m12 = t * u.y * u.z - S * u.x;
            float m20 = t * u.x * u.z - S * u.y;
            float m21 = t * u.y * u.z + S * u.x;
            float m22 = t * u.z * u.z + C;
            return float3x3(m00, m01, m02, m10, m11, m12, m20, m21, m22);
        }

        uniform float _Raymarching_Space_Scale;

        float4x4 ts_to_os_from_triangle_position_manual(VertexData input[3]) {
            // Manually define a reference frame : xy on triangle plane, +x towards symmetric corner, origin on barycenter.
            // Scale them by the length of the small side (assymmetric) ; should allow elongation by "sliding" on chains of blocks.
            // Cons : we only need positions, but they must be sorted by uv to identify them.
            float3 ts_origin_os = (input[0].vertex.xyz + input[1].vertex.xyz + input[2].vertex.xyz) / 3.;
            // Sort positions by uv
            float3 bottom;
            float3 left;
            float3 top_right;
            UNITY_UNROLL
            for(int i = 0; i < 3; i += 1) {
                UNITY_FLATTEN
                if (input[i].uv0.y > 0.8) { top_right = input[i].vertex.xyz; }
                else if (input[i].uv0.y < 0.2) { bottom = input[i].vertex.xyz; }
                else { left = input[i].vertex.xyz; }
            }
            // Build basis vectors
            float3 ts_y_os = (left - bottom) * _Raymarching_Space_Scale; // Scale will be propagated to all 3 axis
            float3 normalized_x = normalize(top_right - ts_origin_os);
            float3 ts_x_os = normalized_x * length(ts_y_os);
            float3 ts_z_os = cross(normalized_x, ts_y_os) * -unity_WorldTransformParams.w; // Handle negative scaling
            // Matrix transformation
            float4x4 ts_to_os = 0;
            ts_to_os._m00_m10_m20 = ts_x_os;
            ts_to_os._m01_m11_m21 = ts_y_os;
            ts_to_os._m02_m12_m22 = ts_z_os;
            ts_to_os._m03_m13_m23_m33 = float4(ts_origin_os, 1);
            return ts_to_os;
        }

        struct Lod {
            uint level;
            float ice_near_to_far; // blend between near and far ice, [0,1]
        };
        Lod lod_level(float4x4 ts_to_ws) {
            Lod lod;
            // Strategy is to compare the camera angular size of a block polygons to the angular size of pixels.
            // Similar criterion as my tessellation experiments. Camera view scale has no effect, only FOV (projection) and resolution.
            #if UNITY_SINGLE_PASS_STEREO
            const float3 camera_position_ws = 0.5 * (unity_StereoWorldSpaceCameraPos[0] + unity_StereoWorldSpaceCameraPos[1]); // Avoid eye inconsistency, take center
            const float2 screen_pixel_size = _ScreenParams.xy * unity_StereoScaleOffset[unity_StereoEyeIndex].xy; // Split render buffer ; 0.5 when split on x
            #else
            const float3 camera_position_ws = _WorldSpaceCameraPos;
            const float2 screen_pixel_size = _ScreenParams.xy;
            #endif

            // Angular size of a pixel
            float2 tan_screen_angular_size = unity_CameraProjection._m00_m11; // View angles for camera https://jsantell.com/3d-projection/#projection-symmetry ; positive
            float2 screen_angular_size = tan_screen_angular_size; // approximation
            float2 pixel_angular_size = screen_angular_size / screen_pixel_size;
            float min_pixel_angular_size = min(pixel_angular_size.x, pixel_angular_size.y); // use highest resolution as threshold
            float pixel_angular_threshold = min_pixel_angular_size * 100; // pixels on screen
            float pixel_angular_threshold_sq = pixel_angular_threshold * pixel_angular_threshold;

            // Angular size of block : compute in WS ; angles should not change if the transformation is of uniform scale.
            float3 block_center_ws = ts_to_ws._m03_m13_m23;
            float block_distance_ws_sq = length_sq(camera_position_ws - block_center_ws);
            float block_trangle_size_ws_sq = length_sq(ts_to_ws._m01_m11_m21); // Size of TS y, used as reference for scaling.
            float block_angular_size_sq = block_trangle_size_ws_sq / block_distance_ws_sq; // again approximate tan(a) ~ a

            // Final LOD
            lod.level = block_angular_size_sq > pixel_angular_threshold_sq ? 0 : 1;
            lod.ice_near_to_far = smoothstep(1, 16, pixel_angular_threshold_sq / block_angular_size_sq);
            return lod;
        }

        struct DislocationAnimationConfig {
            bool show;
            float time;
        };
        DislocationAnimationConfig dislocation_animation_config(VertexData v) {
            // Unpack mesh config
            float global_spatial_delay = v.uv1.x;
            float limb_id = v.uv2.x;
            float limb_coordinate = v.uv2.y; // [-1, 1]

            // Apply global animation first ; always overrides stuff
            DislocationAnimationConfig config;
            config.show = bool(_Replicator_Dislocation_Global.x);
            config.time = max(0., _Replicator_Dislocation_Global.y - global_spatial_delay * _Replicator_Dislocation_Global.z);

            // Arm (show_upper_bound, animation_lower_bound, time, _)
            float3 arm_config = float3(10, 10, 0);
            if (limb_id == 2) { arm_config = _Replicator_Dislocation_LeftArm.xyz; }
            if (limb_id == 3) { arm_config = _Replicator_Dislocation_RightArm.xyz; }
            if (limb_id == 4) { arm_config = _Replicator_Dislocation_LeftLeg.xyz; }
            config.show = config.show && limb_coordinate <= arm_config.x;
            float arm_time = limb_coordinate >= arm_config.y ? arm_config.z : 0;
            config.time = max(config.time, arm_time);
            return config;
        }

        // Generate a random float4(float3 vector + float)
        float4 random_float3_float(uint id) {
            // Pick from table with variation in time
            id += (uint) _Time.x; // time/20, change patterns every 20 sec
            float4 v = baked_random_constants[id % nb_baked_random_constants];
            // Add more variety by reusing the vector with swapped axis ; again use mod 2^n
            UNITY_FLATTEN switch((id / nb_baked_random_constants) % 4) {
                case 0: return v.xyzw;
                case 1: return v.yzxw;
                case 2: return v.zxyw;
                case 3: return v.xzyw;
            }
        }

        #include "Packages/com.llealloo.audiolink/Runtime/Shaders/AudioLink.cginc"

        // Audiolink : https://github.com/llealloo/vrc-udon-audio-link/tree/master/Docs
        // bass : rumble of blocs using the dislocation animation
        // mids : emission along the blocks
        struct TriangleAudioLink {
            float bass_dislocation_time;
            float smoothed_track_threshold_01;
        };
        TriangleAudioLink triangle_audiolink(VertexData v) {
            TriangleAudioLink result;
            result.bass_dislocation_time = 0;
            result.smoothed_track_threshold_01 = 0;

            if (!(_Replicator_AudioLink && AudioLinkIsAvailable())) {
                return result;
            }

            const float history_01 = v.uv1.y; // Defined on avatar and pet as 01 from core to extremities.

            // Bass rumble
            float bass_01 = AudioLinkLerp(ALPASS_AUDIOBASS + float2(history_01 * AUDIOLINK_WIDTH, 0)).r;
            float smoothed_bass_level_01 = AudioLinkData(ALPASS_FILTEREDAUDIOLINK + int2(0 /*smoothing*/, 0 /*bass*/));
            float animation_scale = bass_01 > smoothed_bass_level_01 ? bass_01 : 0; // Ignore low spikes using smoothed threshold 
            float max_animation_time = 0.01;
            result.bass_dislocation_time = bass_01 * max_animation_time;

            // high mids [0, 1] threshold
            float highmids_01 = AudioLinkLerp(ALPASS_AUDIOHIGHMIDS + float2(history_01 * AUDIOLINK_WIDTH, 0)).r;
            float smoothed_highmids_01 = AudioLinkData(ALPASS_FILTEREDAUDIOLINK + int2(0 /*smoothing*/, 2 /*highmids*/)).r;
            float threshold_01 = saturate((highmids_01 - smoothed_highmids_01) / (1 - smoothed_highmids_01)); // Remaps above average part of signal to [0,1]
            result.smoothed_track_threshold_01 = threshold_01;

            return result;
        }

        // random_vec used as float4(xyz = translation speed (m/s WS) + rotation axis (TS), w = rotation speed in rad/s)
        void animate_ts_to_os(inout float4x4 ts_to_os, float4 random_vec, float time) {
            // Rotate triangle space (as values are centered on 0, and rotation operates with an axis on 0 too).
            // This does not touch translation nor w scale;
            float3x3 new_ts_to_os_rot = mul((float3x3) ts_to_os, rotation_matrix(random_vec.xyz, time * random_vec.w));
            for(int i = 0; i < 3; i += 1) {
                ts_to_os[i].xyz = new_ts_to_os_rot[i];
            }
            // Fall translation
            float3 gravity = float3(0, -3, 0); // Unity up = +Y ; heavily reduced for light flakes
            float3 initial_velocity = (random_vec.xyz + float3(0, 1, 0)) * length(unity_ObjectToWorld._m00_m10_m20); // Add vertical bias for snow ; scale to avatar
            float3 translation_ws = initial_velocity * time + 0.5 * gravity * time * time;
            ts_to_os._m03_m13_m23 += mul(unity_WorldToObject, translation_ws);
        }

        // Simpler than a generic inverse, as we go from a nested ortho frame to the parent.
        float4x4 inverse_ts_to_os(float4x4 ts_to_os) {
            // Renaming
            float3 ts_x_os = ts_to_os._m00_m10_m20;
            float3 ts_y_os = ts_to_os._m01_m11_m21;
            float3 ts_z_os = ts_to_os._m02_m12_m22;
            float3 ts_orig_os = ts_to_os._m03_m13_m23;
            // Just project OS unit vectors on TS vectors with inverse scaling.
            float4x4 os_to_ts = 0;
            os_to_ts._m00_m01_m02 = ts_x_os / length_sq(ts_x_os);
            os_to_ts._m10_m11_m12 = ts_y_os / length_sq(ts_y_os);
            os_to_ts._m20_m21_m22 = ts_z_os / length_sq(ts_z_os);
            // Origin
            float3 translation_os = mul((float3x3) os_to_ts, -ts_orig_os);
            os_to_ts._m03_m13_m23_m33 = float4(translation_os, 1);
            return os_to_ts;
        }

        ///////////////////////////////////////////////////
        
        half D_GGX(half NoH, half roughness) {
            half a = NoH * roughness;
            half k = roughness / (1.0 - NoH * NoH + a * a);
            return k * k * (1.0 / UNITY_PI);
        }

        half V_SmithGGXCorrelated(half NoV, half NoL, half roughness) {
            half a2 = roughness * roughness;
            half GGXV = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
            half GGXL = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
            return 0.5 / (GGXV + GGXL);
        }

        // Schlick 1994, "An Inexpensive BRDF Model for Physically-Based Rendering"
        half3 F_Schlick(half3 f0, half f90, half VoH) {
            return f0 + (f90 - f0) * pow(1.0 - VoH, 5);
        }
        half F_Schlick(half f0, half f90, half VoH) {
            return f0 + (f90 - f0) * pow(1.0 - VoH, 5);
        }

        half Fd_Burley(half perceptualRoughness, half NoV, half NoL, half LoH) {
            // Burley 2012, "Physically-Based Shading at Disney"
            half f90 = 0.5 + 2.0 * perceptualRoughness * LoH * LoH;
            half lightScatter = F_Schlick(1.0, f90, NoL);
            half viewScatter = F_Schlick(1.0, f90, NoV);
            return lightScatter * viewScatter;
        }

        half3 getBoxProjection(half3 direction, half3 position, half4 cubemapPosition, half3 boxMin, half3 boxMax) {
            #if defined(UNITY_SPECCUBE_BOX_PROJECTION) && !defined(UNITY_PBS_USE_BRDF2) || defined(FORCE_BOX_PROJECTION)
            if (cubemapPosition.w > 0) {
                half3 factors = ((direction > 0 ? boxMax : boxMin) - position) / direction;
                half scalar = min(min(factors.x, factors.y), factors.z);
                direction = direction * scalar + (position - cubemapPosition.xyz);
            }
            #endif

            return direction;
        }

        half3 EnvBRDFMultiscatter(half2 dfg, half3 f0) {
            return lerp(dfg.xxx, dfg.yyy, f0);
        }

        half computeSpecularAO(half NoV, half ao, half roughness) {
            return clamp(pow(NoV + ao, exp2(-16.0 * roughness - 1.0)) - 1.0 + ao, 0.0, 1.0);
        }

        UNITY_DECLARE_TEX2D(_DFG);

        half3 compute_color(half3 position_ws, half3 normal_ws, half ice_near_to_far) {
            // Ice config
            const half ice_metallicity = 0;
            const half ice_occlusion = 1;
            
            const half3 ice_albedo_near = 0.01 * half3(1, 1, 1);
            const half ice_roughness_near = 0;

            const half3 ice_albedo_far = 0.9 * half3(1, 1, 1);
            const half ice_roughness_far = 0.8;

            // Experiment : ; blend between transparent ice cristal if close, and opaque snow from afar. Not great :(
            const half near_to_far = smoothstep(0, 200, length_sq(position_ws - _WorldSpaceCameraPos));
            const half3 ice_albedo = lerp(ice_albedo_near, ice_albedo_far, ice_near_to_far);
            const half3 ice_roughness = lerp(ice_roughness_near, ice_roughness_far, ice_near_to_far);

            const half3 ray_ws = normalize(position_ws - _WorldSpaceCameraPos);

            // Imported orels ligthing code
            half3 worldSpaceViewDir = -ray_ws;

            half reflectance = 0.5;
            const half3 f0 = 0.16 * reflectance * reflectance * (1 - ice_metallicity) + ice_albedo * ice_metallicity;
            half perceptualRoughness = ice_roughness;

            fixed3 lightDir = _WorldSpaceLightPos0.xyz; // Always a directional light in fwdbase

            half3 lightHalfVector = Unity_SafeNormalize(lightDir + worldSpaceViewDir);
            half lightNoL = saturate(dot(normal_ws, lightDir));
            half lightLoH = saturate(dot(lightDir, lightHalfVector));

            half NoV = abs(dot(normal_ws, worldSpaceViewDir)) + 1e-5;
            half3 pixelLight = lightNoL * _LightColor0.rgb * Fd_Burley(perceptualRoughness, NoV, lightNoL, lightLoH);

            half3 indirectDiffuse = 1;
            #if UNITY_LIGHT_PROBE_PROXY_VOLUME
                UNITY_BRANCH
                if (unity_ProbeVolumeParams.x == 1) {
                    indirectDiffuse = SHEvalLinearL0L1_SampleProbeVolume(half4(normal_ws, 1), position_ws);
                } else {
                    // Mesh has BlendProbes instead of LPPV
                    indirectDiffuse = max(0, ShadeSH9(half4(normal_ws, 1)));   
                }
            #else // No LPPVs enabled project-wide
                indirectDiffuse = max(0, ShadeSH9(half4(normal_ws, 1)));   
            #endif

            half2 dfguv = half2(NoV, perceptualRoughness);
            half2 dfg = UNITY_SAMPLE_TEX2D(_DFG, dfguv).xy;
            half3 energyCompensation = 1.0 + f0 * (1.0 / dfg.y - 1.0);

            half rough = perceptualRoughness * perceptualRoughness;
            half clampedRoughness = max(rough, 0.002);

            half NoH = saturate(dot(normal_ws, lightHalfVector));
            half3 F = F_Schlick(f0, 1, lightLoH);
            half D = D_GGX(NoH, clampedRoughness);
            half V = V_SmithGGXCorrelated(NoV, lightNoL, clampedRoughness);
            F *= energyCompensation;
            half3 directSpecular = max(0, D * V * F) * pixelLight * UNITY_PI;

            half3 reflDir = reflect(-worldSpaceViewDir, normal_ws);
            reflDir = lerp(reflDir, normal_ws, clampedRoughness);

            Unity_GlossyEnvironmentData envData;
            envData.roughness = perceptualRoughness;
            envData.reflUVW = getBoxProjection(reflDir, position_ws, unity_SpecCube0_ProbePosition, unity_SpecCube0_BoxMin.xyz, unity_SpecCube0_BoxMax.xyz);
            half3 indirectSpecular = Unity_GlossyEnvironment(UNITY_PASS_TEXCUBE(unity_SpecCube0), unity_SpecCube0_HDR, envData);

            half horizon = min(1 + dot(reflDir, normal_ws), 1);
            indirectSpecular *= horizon * horizon;

            const half _SpecOcclusion = 0.75;
            dfg.x *= saturate(length(indirectDiffuse) * (1.0 / _SpecOcclusion));
            indirectSpecular *= computeSpecularAO(NoV, ice_occlusion, clampedRoughness) * EnvBRDFMultiscatter(dfg, f0);

            half3 pbr_surface = ice_albedo * (1 - ice_metallicity) * (indirectDiffuse * ice_occlusion + pixelLight) + indirectSpecular + directSpecular;

            // Custom WIP experimental : Refracted transmittance
            half3 refracted_ray = refract(ray_ws, normal_ws, 1.3 /* water refraction index */);
            envData.reflUVW = getBoxProjection(refracted_ray, position_ws, unity_SpecCube0_ProbePosition, unity_SpecCube0_BoxMin.xyz, unity_SpecCube0_BoxMax.xyz);
            half3 refractedSpecular = Unity_GlossyEnvironment(UNITY_PASS_TEXCUBE(unity_SpecCube0), unity_SpecCube0_HDR, envData);
            // https://en.wikipedia.org/wiki/Schlick%27s_approximation of fresnel transmittance T = 1 - R
            half3 transmittance = 1 - F_Schlick(ice_albedo, 1, dot(refracted_ray, -normal_ws));
            return pbr_surface + transmittance * refractedSpecular;

            /* OLD
            const half3 ray_ws = normalize(position_ws - _WorldSpaceCameraPos);
            half3 background_color = DecodeHDR (UNITY_SAMPLE_TEXCUBE(unity_SpecCube0, ray_ws), unity_SpecCube0_HDR);
            float abs_dot_normal_ray = abs(dot(normal_ws, ray_ws));
            float diffuse_ambient = pow(abs(dot(normal_ws, _WorldSpaceLightPos0.xyz)), 3.0);
            half3 cf = lerp(ice_albedo, background_color, abs_dot_normal_ray);
            cf = lerp(cf, 2, diffuse_ambient);
            return lerp(background_color, cf, (0.5 + abs_dot_normal_ray * 0.5));
            */
        }
        
        ///////////////////////////////////////////////////

        uniform float _Raymarching_Geometry_Radius_Scale;

        // Manual baked geometry : 
        // Using windings CW -> CCW -> CW -> ...
        static const float3 baked_quad_strips[16 + 8] = {
            // LOD 0 : inside out box enclosing the cylinder (for DepthLessEqual)
            // 0 : 3 quad faces -y, +z, +y
            float3(-1, -1, -1), float3(1, -1, -1),
            float3(-1, -1, 1), float3(1, -1, 1),
            float3(-1, 1, 1), float3(1, 1, 1),
            float3(-1, 1, -1), float3(1, 1, -1),
            // 1 : 3 quad faces -x, -z, +x
            float3(-1, -1, 1), float3(-1, 1, 1),
            float3(-1, -1, -1), float3(-1, 1, -1),
            float3(1, -1, -1), float3(1, 1, -1),
            float3(1, -1, 1), float3(1, 1, 1),

            // LOD 1 : quad for both z sides
            float3(-1, -1, 0), float3(1, -1, 0),
            float3(-1, 1, 0), float3(1, 1, 0),

            float3(-1, -1, 0), float3(-1, 1, 0),
            float3(1, -1, 0), float3(1, 1, 0),
        };

        struct LodIndexes {
            uint start;
            uint end;
        };
        LodIndexes lod_indexes(uint instance_id, uint level) {
            LodIndexes indexes;
            if (level == 1) {
                indexes.start = instance_id * 8;
                indexes.end = indexes.start + 8;
            } else {
                indexes.start = 16 + instance_id * 4;
                indexes.end = indexes.start + 4;
            }
            return indexes;
        }

        VertexData Vertex (VertexData input) {
            return input;
        }

        [instance(2)]
        [maxvertexcount(8)]
        void Geometry (triangle VertexData input[3], uint snowflake_id : SV_PrimitiveID, uint instance_id : SV_GSInstanceID, inout TriangleStream<FragmentData> stream) {
            UNITY_SETUP_INSTANCE_ID(input[0]);

            DislocationAnimationConfig config = dislocation_animation_config(input[0]);
            if (!config.show) { return; }

            const TriangleAudioLink audiolink = triangle_audiolink(input[0]);
            config.time += audiolink.bass_dislocation_time;

            float4x4 ts_to_os = ts_to_os_from_triangle_position_manual(input);
            animate_ts_to_os(ts_to_os, random_float3_float(snowflake_id), config.time);
            const float4x4 ts_to_ws = mul(unity_ObjectToWorld, ts_to_os);

            const Lod lod = lod_level(ts_to_ws);

            FragmentData output;
            UNITY_INITIALIZE_OUTPUT(FragmentData, output);
            UNITY_TRANSFER_INSTANCE_ID(input[0], output);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
            output.seed_data = make_seed_data(snowflake_id);
            output.camera_ts = mul(inverse_ts_to_os(ts_to_os), mul(unity_WorldToObject, float4(_WorldSpaceCameraPos, 1)));
            output.ts_to_ws_0 = ts_to_ws[0];
            output.ts_to_ws_1 = ts_to_ws[1];
            output.ts_to_ws_2 = ts_to_ws[2];
            output.audiolink_track = audiolink.smoothed_track_threshold_01;
            output.lod_level = lod.level;
            output.ice_near_to_far = lod.ice_near_to_far;

            const float3 geometry_scale = float3(_Raymarching_Geometry_Radius_Scale * snowflake_xy_radius * float2(1, 1), snowflake_z_thickness);
            const LodIndexes indexes = lod_indexes(instance_id, lod.level);
            for (uint i = indexes.start; i < indexes.end; i += 1) {
                float3 vertex_ts = geometry_scale * baked_quad_strips[i];
                output.geometry_ts = vertex_ts;
                output.position_cs = mul(UNITY_MATRIX_VP, mul(ts_to_ws, float4(vertex_ts, 1)));
                UNITY_TRANSFER_FOG(output, output.position_cs);
                stream.Append(output);
            }
        }

        uniform float _Replicator_DebugLOD;

        struct RenderResult {
            half4 color : SV_Target;
            float depth : SV_DepthLessEqual;
        };
        RenderResult Fragment (FragmentData input) {
            UNITY_SETUP_INSTANCE_ID(input);
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

            RenderResult result;
            
            const float3 ray_ts = normalize(input.geometry_ts - input.camera_ts);
            const MaybePoint pixel = raycast_snowflake(input.camera_ts, ray_ts, input.seed_data);
            if (!pixel.valid) { discard; }

            const float4x4 ts_to_ws = float4x4(
                input.ts_to_ws_0,
                input.ts_to_ws_1,
                input.ts_to_ws_2,
                float4(0, 0, 0, 1)
            );

            // Geometry info in world space
            // Less quality than doing 3 raycast, but 3x cheaper and good enough at VR resolutions
            const float3 position_ws = mul(ts_to_ws, float4(pixel.position, 1)).xyz;
            const float3 dx_delta = ddx_fine(position_ws);
            const float3 dy_delta = ddy_fine(position_ws);
            const float3 normal_ws = normalize(cross(dy_delta, dx_delta)); // Looks good, checked with debug shading

            // Lighting
            result.color = half4(compute_color(position_ws, normal_ws, input.ice_near_to_far), 1);
            //result.color.rgb += half3(0, 0.4, 1) * input.audiolink_track * 0.5; FIXME integrate in a nicer way (lighting)

            // Post processing
            result.color = lerp(result.color, half4(1 - input.lod_level, input.lod_level, 0, 1), _Replicator_DebugLOD * 0.8);
            UNITY_APPLY_FOG(input.fogCoord, result.color);

            // Depth
            const float4 pos = mul(UNITY_MATRIX_VP, float4(position_ws, 1));
            result.depth = pos.z / pos.w;
            return result;
        }
        ENDCG
    }
}
}
