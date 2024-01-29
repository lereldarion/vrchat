// Render blocs as raymarched fake snowflakes, unlit
// Adapted from https://www.shadertoy.com/view/Xsd3zf

// TODO match raymarched space to ws/os
// TODO add geometry pass to retrieve primitive_id and create support geometry

Shader "Lereldarion/Snowflakes_Bk" {
Properties {
    _MainTex("Albedo for fallback", 2D) =  "white" { }

    _Replicator_Dislocation_Global("Dislocation Global (show, time, spatial_delay_factor, _)", Vector) = (1, 0, 0, 0)
    _Replicator_Dislocation_LeftArm("Dislocation LeftArm (show_upper_bound, animation_lower_bound, time, _)", Vector) = (1, 1, 0, 0)
    _Replicator_Dislocation_RightArm("Dislocation RightArm (show_upper_bound, animation_lower_bound, time, _)", Vector) = (1, 1, 0, 0)

    _Pos("Pos", Vector) = (0, 0, 1, 0)
}

SubShader {
    Tags {
        "RenderType" = "TransparentCutout"
        "Queue" = "AlphaTest"
        "VRCFallback" = "ToonCutoutDoubleSided"
    }

    Cull Off

    Pass
    {
        CGPROGRAM
        #pragma vertex vertex_stage
        #pragma fragment fragment_stage
		#pragma multi_compile_instancing

        #include "UnityCG.cginc"
        #pragma target 5.0

        ///////////////////////////////////////////////////

        half length_sq (half2 v) { return dot(v, v); }
        half length_sq (half3 v) { return dot(v, v); }

        // Hash / noise
        static const half4 NC0 = half4(0, 157, 113, 270);
        static const half4 NC1 = half4(1, 158, 114, 271);

        // [0-1]
        float4 hash4 (float4 n) { return frac(sin(n) * 1399763.5453123); }
        half4 hash4 (half4 n) { return frac(sin(n) * 1399763.5453123); }

        // [0-1]
        half noise2 (half2 x) {
            half2 p = floor(x);
            half2 f = frac(x);
            f = f * f * (3.0 - 2.0 * f);
            half n = p.x + p.y * 157.0;
            half4 h = hash4(n + half4(NC0.xy, NC1.xy));
            half2 s1 = lerp(h.xy, h.zw, f.xx);
            return lerp(s1.x, s1.y, f.y);
        }
        // [0-1], more details
        half noise222 (half2 x, half2 y, half2 z) {
            half4 lx = x.xyxy * y.xxyy;
            half4 p = floor(lx);
            half4 f = frac(lx);
            f = f * f * (3.0 - 2.0 * f);
            half2 n = p.xz + p.yw * 157.0;
            half4 h = lerp(hash4(n.xxyy + NC0.xyxy), hash4(n.xxyy + NC1.xyxy), f.xxzz);
            return dot(lerp(h.xz, h.yw, f.yw), z);
        }
        // [-0.5, 0.5]
        half noise2_lod (half2 rad, half resolution) {
            half r;
            if (resolution < 0.0015) {
                r = noise222(rad, half2(20.6, 100.6), half2(0.9, 0.1));
            } else if (resolution < 0.005) {
                r = noise2(rad * 20.6);
            } else {
                r = noise2(rad * 10.3); // visually different from above ; remove ?
            }
            return r - 0.5;
        }

        // [0-1]
        half noise3 (half3 x) {
            half3 p = floor(x);
            half3 f = frac(x);
            f = f * f * (3.0 - 2.0 * f);
            half n = p.x + dot(p.yz, half2(157.0, 113.0));
            half4 s1 = lerp(hash4(n + NC0), hash4(n + NC1), f.xxxx);
            return lerp(lerp(s1.x, s1.y, f.y), lerp(s1.z, s1.w, f.y), f.z);
        }

        // Raymarching

        struct RaymarchingResult {
            bool hit;
            half3 position; // Point in raymarching space
        };

        RaymarchingResult raycast_snowflake (
            half3 pos, // rotated mr, not normalized, seems to be camera pos
            half3 ray, // rotated mr, normalized, from 0 to camera
            half3 seed_data,
            half resolution //
        ) {
            const half zoom = 2.; // use this to change details. optimal 0.1 - 4.0.
            const half radius = 0.25; // above too much details
            const int iterations = 15;
            
            const half radius_sq = radius * radius;

            // Snowflake geometry
            const half3 plane_normal = half3(0, 0, 1); // unrotated, plane of the snowflake
            const half thickness = 0.0125; // Measured along the normal
            
            const half inv_ray_projection_factor = 1.0 / dot(plane_normal, ray); 
            const half thickness_facing = thickness * sign(inv_ray_projection_factor); // + if ray to front, - ray from back
            half ds = 2 * thickness_facing * inv_ray_projection_factor; // always positive. 2 * ray distance traversing the thickness of snowflake

            // Symmetrize pos using (0), place parallel ray at pos, then find point on plane dot(plane_normal, v) = -thickness_facing.
            half3 p_back = ray * (dot(plane_normal, pos) - thickness_facing) * inv_ray_projection_factor - pos; // dot(p_back, plane_normal) = -tf, starts at back plane
            half3 p_front = p_back + ray * ds; // point at plane dot(plane_normal, v) = +thickness_facing

            // Project to plane dot(plane_normal, v)=0 and get "planar" distance to origin.
            const half back_sf_planar_sqdist = length_sq(p_back + plane_normal * thickness_facing);
            const half front_sf_planar_sqdist = length_sq(p_front - plane_normal * thickness_facing);
            bool ray_intersects_cylinder_faces = min(back_sf_planar_sqdist, front_sf_planar_sqdist) < radius_sq;
            
            const half3 ray_plane_normal = normalize(cross(ray, plane_normal)); // plane normal to snowflake_plane and containing the ray. tangent to snowflake_plane
            const half mind = dot(pos, ray_plane_normal);
            const half3 ray_90_in_ray_plane = cross(ray, ray_plane_normal); // a vector 90d from ray in the ray plane
            const half d = dot(ray_90_in_ray_plane, pos) / dot(ray_90_in_ray_plane, plane_normal);
            bool ray_through_sides = abs(mind) < radius && abs(d) <= thickness; // not entirely sure.
            
            RaymarchingResult result;
            result.hit = false;
            result.position = half3(0, 0, 0);

            if (ray_intersects_cylinder_faces || ray_through_sides) {
                if (back_sf_planar_sqdist >= radius_sq) {
                    // Seems to reposition p_back, p_front, and ds for the case where the ray go through the sides
                    half3 n3 = cross(plane_normal, ray_plane_normal);
                    half a = rsqrt(radius_sq - mind * mind) * abs(dot(ray, n3));
                    half3 dt = ray / a;
                    p_back = -d * plane_normal - mind * ray_plane_normal - dt;
                    if (front_sf_planar_sqdist >= radius_sq) {
                        p_front = -d * plane_normal - mind * ray_plane_normal + dt;
                    }
                    ds = abs(dot(p_front - p_back, ray)); // moved abs here, as initial ds is always positive 
                }

                // Tuning of raymarching stepping I guess. All 3 have visual impact.
                ds = (ds + 0.1) / iterations;
                ds = lerp(thickness, ds, 0.2);
                ds = max(ds, 0.01); // Ensure performance by minimum step ?

                const half depth_scale = 0.2 / thickness;
                const half internal_radius = 0.35 / radius; // Controls the secondary radius inside the large one.
                ray = ray * ds * 5.0;

                result.position = p_back;
                for (int m = 0; m < iterations; m += 1) {
                    half l = length(result.position.xy);
                    // Lobe construction
                    half2 c3 = abs(result.position.xy / l);
                    if (c3.x > 0.5) {
                        c3 = abs(c3 * 0.5 + half2(-c3.y , c3.x) * 0.86602540 /*sin(pi/3) or cos(pi/6)*/);
                    }
                    const half g = l + c3.x * c3.x;
                    // 
                    l *= zoom;
                    half h = l - radius - 0.1;
                    l = pow(l, seed_data.z) + 0.1;
                    const half noise = noise2_lod(c3 * l + seed_data.xy, resolution);
                    const half create_depth_variations = lerp(noise, 1.0, abs(result.position.z * depth_scale));
                    h = max(h, create_depth_variations) + g * internal_radius - 0.245;
                    if (h < resolution * 20.0 || abs(result.position.z) > thickness + 0.01) {
                        break;
                    }
                    result.position += ray * h;
                    ray *= 0.99;
                }
                if (abs(result.position.z) < thickness + 0.01) {
                    result.hit = true;
                }
            }
            return result;
        }

        half3 filter_flake (
            half3 color,
            half3 pos,
            half3 ray, half3 ray_dx, half3 ray_dy, // normalized
            half3 light,
            half3 seed_data, half resolution
        ) {
            const half3 ice_color = half3(0.0, 0.4, 1.0);

            RaymarchingResult center = raycast_snowflake(pos, ray, seed_data, resolution);
            if (!center.hit) { discard; }
            RaymarchingResult dx = raycast_snowflake(pos, ray_dx, seed_data, resolution);
            RaymarchingResult dy = raycast_snowflake(pos, ray_dy, seed_data, resolution);
            if (!(dx.hit && dy.hit)) { discard; }

            half3 snowflake_normal = normalize(cross(dx.position - center.position, dy.position - center.position));

            // lighting
            half abs_dot_normal_ray = abs(dot(snowflake_normal, ray));
            half diffuse_ambient = pow(abs(dot(snowflake_normal, light)), 3.0);
            half3 cf = lerp(ice_color, color * 10.0, abs_dot_normal_ray);
            cf = lerp(cf, 2, diffuse_ambient);
            return lerp(color, cf, (0.5 + abs_dot_normal_ray * 0.5));
        }


        ///////////////////////////////////////////////////

        struct VertexData {
            float4 position_os : POSITION;
            float2 uv0 : TEXCOORD0;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        struct FragmentData {
            float4 position_cs : SV_POSITION;
            half3 seed_data : TEXCOORD0;
            float2 uv0 : TEXCOORD1;

            float3 camera_os : TEXCOORD2;
            float3 geometry_to_camera_os : TEXCOORD3;
            float3 light_to_geometry_os : TEXCOORD4;        

            UNITY_VERTEX_INPUT_INSTANCE_ID
            UNITY_VERTEX_OUTPUT_STEREO
        };

        half3 make_seed_data(uint snowflake_id) {
            half2 seed = half2(0, 1 + snowflake_id); floor(_Time.yz);
            half powr = noise3(half3(seed, 1) * 10.0) * 1.9 + 0.1;
            return half3(seed, powr);
        }

        FragmentData vertex_stage (VertexData input) {
            UNITY_SETUP_INSTANCE_ID(input);
            FragmentData output;
            output.position_cs = UnityObjectToClipPos(input.position_os);
            output.uv0 = input.uv0;

            // TODO use triangle id from geometry pass
            #if defined(UNITY_INSTANCING_ENABLED)
            const float id = unity_InstanceID;
            #else
            const float id = 0;
            #endif
            output.seed_data = make_seed_data(id);

            output.camera_os = mul(unity_WorldToObject, _WorldSpaceCameraPos).xyz;
            output.geometry_to_camera_os = output.camera_os - input.position_os.xyz;
            output.light_to_geometry_os = input.position_os.xyz - mul(unity_WorldToObject, _WorldSpaceLightPos0);
            
            UNITY_TRANSFER_INSTANCE_ID(input, output);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
            return output;
        }

        uniform float4 _Pos;
        half4 fragment_stage (FragmentData input) : SV_Target {
            UNITY_SETUP_INSTANCE_ID(input);
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

            float2 inv_pixel_size = _ScreenParams.zw - 1;
            float resolution = min(inv_pixel_size.x, inv_pixel_size.y);

            //float3 pos = input.camera_os;
            //float3 ray = normalize(input.geometry_to_camera_os);
            
            float3 pos = _Pos.xyz; // should probably stay constant
            float3 ray = normalize(float3(input.uv0 * 2 - 1, 2));
            float3 ray_dx = normalize(ray + float3(0, resolution * 2, 0)); // bad
            float3 ray_dy = normalize(ray + float3(resolution * 2, 0, 0));
            
            float3 light = normalize(float3(1, 0, 1));

            half3 color = filter_flake(
                half3(0, 0, 0), // current color
                pos,
                ray, ray_dx, ray_dy,
                light,
                input.seed_data,
                resolution
            );
            return half4(color, 1);
        }

        ENDCG
    }
}
}
