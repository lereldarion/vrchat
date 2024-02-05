// Render blocs as raymarched snowflakes
// Adapted from https://www.shadertoy.com/view/Xsd3zf
// Has some Forward Rendering lighting. No add pass or shadow casting to avoid doing marching too much.

Shader "Lereldarion/Replicator/Snowflake" {
Properties {
    _MainTex("Fallback", 2D) = "white" { }

    // Raymarching config
    _Raymarching_Zoom("Zoom", Range(0.1, 4.)) = 3
    _Raymarching_Space_Scale("Snowflake scale", Range(0.1, 10)) = 2
    _Raymarching_Geometry_Radius_Scale("Support Geometry Radius Scale", Range(0.4, 1)) = 0.6 // At higher zoom the flake does not occupy all of the radius-based geometry

    // Base animations
    _Replicator_Dislocation_Global("Dislocation Global (show, time, spatial_delay_factor, _)", Vector) = (1, 0, 0, 0)
    _Replicator_Dislocation_LeftArm("Dislocation LeftArm (show_upper_bound, animation_lower_bound, time, _)", Vector) = (1, 1, 0, 0)
    _Replicator_Dislocation_RightArm("Dislocation RightArm (show_upper_bound, animation_lower_bound, time, _)", Vector) = (1, 1, 0, 0)
    _Replicator_Dislocation_LeftLeg("Dislocation LeftLeg (show_upper_bound, animation_lower_bound, time, _)", Vector) = (1, 1, 0, 0)

    [ToggleUI] _Replicator_AudioLink("Enable AudioLink", Float) = 1
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

        CGPROGRAM
        #pragma vertex Vertex
        #pragma geometry Geometry
        #pragma fragment Fragment
		#pragma multi_compile_instancing
		#pragma multi_compile_fwdbase

        // For avatar only
        #pragma skip_variants DYNAMICLIGHTMAP_ON LIGHTMAP_ON LIGHTMAP_SHADOW_MIXING DIRLIGHTMAP_COMBINED

        #include "UnityCG.cginc"
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
            float3 seed_data : TEXCOORD0;

            float3 camera_ts : TEXCOORD1;
            float3 geometry_ts : TEXCOORD2;

            float4 ts_to_ws_0 : TEXCOORD3;
            float4 ts_to_ws_1 : TEXCOORD4;
            float4 ts_to_ws_2 : TEXCOORD5;

            float3 camera_to_geometry_ws : TEXCOORD6;

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

        // [0-1], more details
        float noise222 (float2 x, float2 y, float2 z) {
            float4 lx = x.xyxy * y.xxyy;
            float4 p = floor(lx);
            float4 f = frac(lx);
            f = f * f * (3.0 - 2.0 * f);
            float2 n = p.xz + p.yw * 157.0;
            float4 h = lerp(hash4(n.xxyy + NC0.xyxy), hash4(n.xxyy + NC1.xyxy), f.xxzz);
            return dot(lerp(h.xz, h.yw, f.yw), z);
        }
        // [-0.5, 0.5]
        float noise2_centered (float2 p) {
            // It initially used a LOD switch to 3 versions with various details.
            // Removed for simplicity. Maybe swap to noise texture to remove sin calls.
            return noise222(p, float2(20.6, 100.6), float2(0.9, 0.1)) - 0.5;
        }

        // [0-1]
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
                        + (position_radius + c3.x * c3.x) * (fill_factor / snowflake_xy_radius) // pos snowflake_xy_radius + lobe tweak, normalised to [0, 0.35]
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

        float object_to_world_scale() {
            return length(unity_ObjectToWorld._m00_m01_m02);
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

        // Audiolink rumble of blocks https://github.com/llealloo/vrc-udon-audio-link/tree/master/Docs
        float audiolink_bass_dislocation_time(VertexData v) {
            if (!(_Replicator_AudioLink && AudioLinkIsAvailable())) {
                return 0;
            }

            float history_01 = v.uv1.y; // Defined on avatar and pet as 01 from core to extremities.
            float bass_01 = AudioLinkLerp(ALPASS_AUDIOBASS + float2(history_01 * AUDIOLINK_WIDTH, 0)).r;

            // Ignore low spikes using smoothed threshold 
            float smoothed_bass_level_01 = AudioLinkData(ALPASS_FILTEREDAUDIOLINK + int2(0 /*smoothing*/, 0 /*bass*/));
            float animation_scale = bass_01 > smoothed_bass_level_01 ? bass_01 : 0;

            float max_animation_time = 0.01;
            return bass_01 * max_animation_time;
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
            float3 initial_velocity = random_vec.xyz * object_to_world_scale() + float3(0, 1, 0); // Add vertical bias for snow
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
        LodIndexes lod_indexes(uint instance_id) {
            float3 object_origin_ws = unity_ObjectToWorld._m03_m13_m23; // Translation components https://en.wikibooks.org/wiki/Cg_Programming/Vertex_Transformations
            #if UNITY_SINGLE_PASS_STEREO
            float3 camera_origin_ws = 0.5 * (unity_StereoWorldSpaceCameraPos[0] + unity_StereoWorldSpaceCameraPos[1]);
            #else
            float3 camera_origin_ws = _WorldSpaceCameraPos;
            #endif
            float camera_distance_squared = length_sq(object_origin_ws - camera_origin_ws);

            // Shorten distance due to higher cost, compared to the original
            float world_distance_lod_transition = 2.5 * object_to_world_scale();

            LodIndexes indexes;
            if (camera_distance_squared < (world_distance_lod_transition * world_distance_lod_transition)) {
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

            config.time += audiolink_bass_dislocation_time(input[0]);

            float4x4 ts_to_os = ts_to_os_from_triangle_position_manual(input);
            animate_ts_to_os(ts_to_os, random_float3_float(snowflake_id), config.time);
            const float4x4 ts_to_ws = mul(unity_ObjectToWorld, ts_to_os);

            FragmentData output;
            UNITY_TRANSFER_INSTANCE_ID(input[0], output);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
            output.seed_data = make_seed_data(snowflake_id);
            output.camera_ts = mul(inverse_ts_to_os(ts_to_os), mul(unity_WorldToObject, float4(_WorldSpaceCameraPos, 1)));
            output.ts_to_ws_0 = ts_to_ws[0];
            output.ts_to_ws_1 = ts_to_ws[1];
            output.ts_to_ws_2 = ts_to_ws[2];

            const float3 geometry_scale = float3(_Raymarching_Geometry_Radius_Scale * snowflake_xy_radius * float2(1, 1), snowflake_z_thickness);
            const LodIndexes indexes = lod_indexes(instance_id);
            for (uint i = indexes.start; i < indexes.end; i += 1) {
                float3 vertex_ts = geometry_scale * baked_quad_strips[i];
                output.geometry_ts = vertex_ts;
                float3 vertex_ws = mul(ts_to_ws, float4(vertex_ts, 1)).xyz;
                output.camera_to_geometry_ws = vertex_ws - _WorldSpaceCameraPos;
                output.position_cs = mul(UNITY_MATRIX_VP, float4(vertex_ws, 1));
                stream.Append(output);
            }
        }

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
            const float3 normal_ws = normalize(cross(dx_delta, dy_delta));
            const float3 ray_ws = normalize(input.camera_to_geometry_ws);
            const float3 reflection_ws = reflect(-ray_ws, normal_ws);

            // Lighting
            const half3 ice_color = half3(0.0, 0.4, 1.0);

            half3 background_color = DecodeHDR (UNITY_SAMPLE_TEXCUBE(unity_SpecCube0, ray_ws), unity_SpecCube0_HDR);
            half3 reflected_color = DecodeHDR (UNITY_SAMPLE_TEXCUBE(unity_SpecCube0, reflection_ws), unity_SpecCube0_HDR);

            // TODO reflection
            
            float abs_dot_normal_ray = abs(dot(normal_ws, ray_ws));
            float diffuse_ambient = pow(abs(dot(normal_ws, _WorldSpaceLightPos0.xyz)), 3.0);
            half3 cf = lerp(ice_color, background_color, abs_dot_normal_ray);
            cf = lerp(cf, 2, diffuse_ambient);
            half3 final_color = lerp(background_color, cf, (0.5 + abs_dot_normal_ray * 0.5));
            result.color = half4(final_color, 1);

            // Depth
            const float4 position_cs = mul(UNITY_MATRIX_VP, float4(position_ws, 1));
            result.depth = position_cs.z / position_cs.w;
            return result;
        }
        ENDCG
    }
}
}
