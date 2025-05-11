// Render blocs as raymarched fake snowflakes, unlit
// Adapted from https://www.shadertoy.com/view/Xsd3zf

// TODO match raymarched space to ws/os
// TODO add geometry pass to retrieve primitive_id and create support geometry

Shader "Lereldarion/Snowflakes_Os" {
Properties {
    _MainTex("Albedo for fallback", 2D) =  "white" { }

    _Raymarching_Zoom("Zoom", Range(0.1, 4.)) = 2.
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

        struct RaymarchingResult {
            bool hit;
            float3 position; // Point in raymarching space
        };
        RaymarchingResult raycast_snowflake (
            float3 camera, float3 ray, // OS, ray = from camera to geometry normalized
            float3 seed_data
        ) {
            const float zoom = _Raymarching_Zoom; // use this to change details. optimal 0.1 - 4.0.
            const float snowflake_radius = 0.25; // above too much details
            
            // Snowflake geometry : flat 
            const float3 snowflake_origin = float3(0, 0, 0);
            const float3 snowflake_normal = float3(0, 0, 1); // plane of the snowflake in OS
            const float thickness = 0.0125; // Measured along the normal ; Z thickness
            
            const float plane_to_camera_z = dot(camera - snowflake_origin, snowflake_normal);
            const float camera_side = sign(plane_to_camera_z); // +1 if forward, -1 if back
            const float thickness_facing = thickness * camera_side; // +thickness if camera.z>0, -thickness instead
            
            const float plane_z_to_ray_factor = 1. / dot(ray, snowflake_normal);
            const float3 p_start = camera + (thickness_facing - plane_to_camera_z) * plane_z_to_ray_factor * ray; // hit first face plane
            const float3 p_end = camera + (-thickness_facing - plane_to_camera_z) * plane_z_to_ray_factor * ray; // hit to back face plane
            const float ray_length_through_snowflake = 2 * thickness_facing * -plane_z_to_ray_factor;

            const float radius_sq = snowflake_radius * snowflake_radius;
            const float start_radius_sq = length_sq(p_start - (snowflake_origin + thickness_facing * snowflake_normal));
            const float end_radius_sq = length_sq(p_end - (snowflake_origin - thickness_facing * snowflake_normal));
            bool ray_intersects_cylinder_faces = (ray_length_through_snowflake > 0) && min(start_radius_sq, end_radius_sq) < radius_sq;

            /*const float inv_ray_projection_factor = 1.0 / dot(snowflake_normal, ray);
            const float thickness_facing = thickness * sign(inv_ray_projection_factor); // + if ray to front, - ray from back
            float ds = 2 * thickness_facing * inv_ray_projection_factor; // always positive. 2 * ray distance traversing the thickness of snowflake
            // Symmetrize camera using (0), place parallel ray at camera, then find point on plane dot(snowflake_normal, v) = -thickness_facing.
            float3 p_back = ray * (dot(snowflake_normal, camera) - thickness_facing) * inv_ray_projection_factor - camera; // dot(p_back, snowflake_normal) = -tf, starts at back plane
            float3 p_front = p_back + ray * ds; // point at plane dot(snowflake_normal, v) = +thickness_facing

            // Project to plane dot(snowflake_normal, v)=0 and get "planar" distance to origin.
            const float back_sf_planar_sqdist = length_sq(p_back + snowflake_normal * thickness_facing);
            const float front_sf_planar_sqdist = length_sq(p_front - snowflake_normal * thickness_facing);
            bool ray_intersects_cylinder_faces = min(back_sf_planar_sqdist, front_sf_planar_sqdist) < radius_sq;
            
            const float3 ray_plane_normal = normalize(cross(ray, snowflake_normal)); // plane normal to snowflake_plane and containing the ray. tangent to snowflake_plane
            const float mind = dot(camera, ray_plane_normal);
            const float3 ray_90_in_ray_plane = cross(ray, ray_plane_normal); // a vector 90d from ray in the ray plane
            const float d = dot(ray_90_in_ray_plane, camera) / dot(ray_90_in_ray_plane, snowflake_normal);
            bool ray_through_sides = abs(mind) < snowflake_radius && abs(d) <= thickness; // not entirely sure.*/
            
            RaymarchingResult result;
            result.hit = false;
            result.position = p_start;

            if (ray_intersects_cylinder_faces) {
                /*if (back_sf_planar_sqdist >= radius_sq) {
                    // Seems to reposition p_back, p_front, and ds for the case where the ray go through the sides
                    float3 n3 = cross(snowflake_normal, ray_plane_normal);
                    float a = rsqrt(radius_sq - mind * mind) * abs(dot(ray, n3));
                    float3 dt = ray / a;
                    p_back = -d * snowflake_normal - mind * ray_plane_normal - dt;
                    if (front_sf_planar_sqdist >= radius_sq) {
                        p_front = -d * snowflake_normal - mind * ray_plane_normal + dt;
                    }
                    ds = abs(dot(p_front - p_back, ray)); // moved abs here, as initial ds is always positive 
                }*/

                // Tuning of raymarching stepping. All 3 have visual impact.
                const int iterations = 15;
                float ds = ray_length_through_snowflake;
                ds = ds / iterations;
                ds = lerp(thickness, ds, 0.2); // 80% thickness
                ds = max(ds, 0.01); // Ensure performance by minimum step ?
                ray = ray * ds * 5.0; // [3, 10] tested and ok.

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
                    const float up_biased_noise = lerp(noise, 1.0, abs(result.position.z * (0.2 / thickness))); // blend with positive bias, up to 0.2 at |z|=thickness. 0.2 critical.
                    const float fill_factor = 0.35; // 0.25 starts making rings, nice up to 1, afterwards it becomes very skinny
                    const float displacement = 
                        max(
                            zoomed_radius - snowflake_radius - 0.1, // [-snowflake_radius - 0.1, (zoom-1) * snowflake_radius - 0.1]. 0.1 kills outer circle sometimes
                            up_biased_noise // [-0.5, 0.6]
                        )
                        + (position_radius + c3.x * c3.x) * (fill_factor / snowflake_radius) // pos snowflake_radius + lobe tweak, normalised to [0, 0.35]
                        - 0.7 * fill_factor;
                    if (displacement < 0 || abs(result.position.z) > thickness + 0.01) {
                        break; // Stop if negative or out of bounds
                    }
                    result.position += ray * displacement;
                    ray *= 0.99;
                }
                if (abs(result.position.z) < thickness + 0.01) {
                    result.hit = true;
                }
            }
            return result;
        }

        float3 filter_flake (
            float3 color,
            float3 camera,
            float3 ray, // normalized
            float3 light,
            float3 seed_data
        ) {
            const float3 ice_color = float3(0.0, 0.4, 1.0);

            RaymarchingResult pixel = raycast_snowflake(camera, ray, seed_data);
            if (!pixel.hit) { discard; }

            // Less quality than doing 3 raycast, but way cheaper.
            float3 dx_delta = ddx_fine(pixel.position);
            float3 dy_delta = ddy_fine(pixel.position);
            float3 snowflake_normal = normalize(cross(dx_delta, dy_delta));

            /* TODO  marching for derivatives should be done on the face coordinates, with snowflake_radius related resolution
            float2 inv_pixel_size = _ScreenParams.zw - 1;
            float3 ray_dx = normalize(ray + float3(0, inv_pixel_size.y * 2, 0)); // bad
            float3 ray_dy = normalize(ray + float3(inv_pixel_size.x * 2, 0, 0));
            RaymarchingResult dx = raycast_snowflake(camera, ray_dx, seed_data);
            RaymarchingResult dy = raycast_snowflake(camera, ray_dy, seed_data);
            if (!(dx.hit && dy.hit)) { discard; }
            float3 snowflake_normal = normalize(cross(dx.position - pixel.position, dy.position - pixel.position));
            */

            // lighting
            float abs_dot_normal_ray = abs(dot(snowflake_normal, ray));
            float diffuse_ambient = pow(abs(dot(snowflake_normal, light)), 3.0);
            float3 cf = lerp(ice_color, color * 10.0, abs_dot_normal_ray);
            cf = lerp(cf, 2, diffuse_ambient);
            
            // TODO use reflection box ? depth ?
            
            return lerp(color, cf, (0.5 + abs_dot_normal_ray * 0.5));
        }

        ///////////////////////////////////////////////////

        struct VertexData {
            float4 position_os : POSITION;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        struct FragmentData {
            float4 position_cs : SV_POSITION;
            float3 seed_data : TEXCOORD0;

            float3 camera_os : TEXCOORD1;
            float3 camera_to_geometry_os : TEXCOORD2;
            float3 light_to_geometry_os : TEXCOORD3;        

            UNITY_VERTEX_INPUT_INSTANCE_ID
            UNITY_VERTEX_OUTPUT_STEREO
        };

        float3 make_seed_data(uint snowflake_id) {
            float2 seed = float2(0, 1 + snowflake_id); floor(_Time.yz);
            float powr = noise3(float3(seed, 1) * 10.0) * 1.9 + 0.1;
            return float3(seed, powr);
        }

        FragmentData vertex_stage (VertexData input) {
            UNITY_SETUP_INSTANCE_ID(input);
            FragmentData output;
            output.position_cs = UnityObjectToClipPos(input.position_os);

            // TODO use triangle id from geometry pass
            #if defined(UNITY_INSTANCING_ENABLED)
            const float id = unity_InstanceID;
            #else
            const float id = 0;
            #endif
            output.seed_data = make_seed_data(id);

            output.camera_os = mul(unity_WorldToObject, float4(_WorldSpaceCameraPos, 1)).xyz;
            output.camera_to_geometry_os = input.position_os.xyz - output.camera_os;
            output.light_to_geometry_os = input.position_os.xyz - mul(unity_WorldToObject, _WorldSpaceLightPos0).xyz;
            
            UNITY_TRANSFER_INSTANCE_ID(input, output);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
            return output;
        }

        uniform float4 _Pos;
        float4 fragment_stage (FragmentData input) : SV_Target {
            UNITY_SETUP_INSTANCE_ID(input);
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);


            float3 camera = input.camera_os;
            float3 ray = normalize(input.camera_to_geometry_os);
            float3 light = normalize(input.light_to_geometry_os);
            
            float3 color = filter_flake(
                float3(0, 0, 0), // current color
                camera, ray, light,
                input.seed_data
            );
            return float4(color, 1);
        }

        ENDCG
    }
}
}
