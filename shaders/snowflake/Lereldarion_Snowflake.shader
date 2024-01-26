// Render blocs as raymarched fake snowflakes, unlit
// Adapted from https://www.shadertoy.com/view/Xsd3zf

// TODO match raymarched space to ws/os
// TODO add geometry pass to retrieve primitive_id and create support geometry

Shader "Lereldarion/Snowflakes" {
Properties {
    _Replicator_Dislocation_Global("Dislocation Global (show, time, spatial_delay_factor, _)", Vector) = (1, 0, 0, 0)
    _Replicator_Dislocation_LeftArm("Dislocation LeftArm (show_upper_bound, animation_lower_bound, time, _)", Vector) = (1, 1, 0, 0)
    _Replicator_Dislocation_RightArm("Dislocation RightArm (show_upper_bound, animation_lower_bound, time, _)", Vector) = (1, 1, 0, 0)
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

        struct VertexData {
            float4 position_os : POSITION;
            float2 uv0 : TEXCOORD0;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        struct FragmentData {
            float4 position_cs : SV_POSITION;
            float2 uv0 : TEXCOORD0;
            float2 snowflake_seed : TEXCOORD1;

            float3 camera_os : TEXCOORD2;
            float3 camera_to_geometry_os : TEXCOORD3;
            float3 light_to_geometry_os : TEXCOORD4;            

            UNITY_VERTEX_INPUT_INSTANCE_ID
            UNITY_VERTEX_OUTPUT_STEREO
        };

        FragmentData vertex_stage (VertexData input) {
            UNITY_SETUP_INSTANCE_ID(input);
            FragmentData output;
            output.position_cs = UnityObjectToClipPos(input.position_os);
            output.uv0 = input.uv0;

            #if defined(UNITY_INSTANCING_ENABLED)
            const float id = unity_InstanceID;
            #else
            const float id = 0;
            #endif
            output.snowflake_seed = float2(0, 1 + id) ; floor(_Time.yz); // FIXME use instance id

            output.camera_os = mul(unity_WorldToObject, _WorldSpaceCameraPos).xyz;
            output.camera_to_geometry_os = input.position_os.xyz - output.camera_os;
            output.light_to_geometry_os = input.position_os.xyz - mul(unity_WorldToObject, _WorldSpaceLightPos0);
            
            UNITY_TRANSFER_INSTANCE_ID(input, output);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
            return output;
        }

        ///////////////////////////////////////////////////

        half length_sq (half2 v) { return dot(v, v); }
        half length_sq (half3 v) { return dot(v, v); }

        // Hash / noise
        static const half4 NC0 = half4(0, 157, 113, 270);
        static const half4 NC1 = half4(1, 158, 114, 271);

        half4 hash4 (half4 n) { return frac(sin(n) * 1399763.5453123); }

        half noise2 (half2 x) {
            half2 p = floor(x);
            half2 f = frac(x);
            f = f * f * (3.0 - 2.0 * f);
            half n = p.x + p.y * 157.0;
            half4 h = hash4(n + half4(NC0.xy, NC1.xy));
            half2 s1 = lerp(h.xy, h.zw, f.xx);
            return lerp(s1.x, s1.y, f.y);
        }

        half noise222 (half2 x, half2 y, half2 z) {
            half4 lx = x.xyxy * y.xxyy;
            half4 p = floor(lx);
            half4 f = frac(lx);
            f = f * f * (3.0 - 2.0 * f);
            half2 n = p.xz + p.yw * 157.0;
            half4 h = lerp(hash4(n.xxyy + NC0.xyxy), hash4(n.xxyy + NC1.xyxy), f.xxzz);
            return dot(lerp(h.xz, h.yw, f.yw), z);
        }

        half noise3 (half3 x) {
            half3 p = floor(x);
            half3 f = frac(x);
            f = f * f * (3.0 - 2.0 * f);
            half n = p.x + dot(p.yz, half2(157.0,113.0));
            half4 s1 = lerp(hash4(n + NC0), hash4(n + NC1), f.xxxx);
            return lerp(lerp(s1.x, s1.y, f.y), lerp(s1.z, s1.w, f.y), f.z);
        }

        // Raymarching

        half lod_noise (half2 rad, half resolution) {
            half r;
            if (resolution < 0.0015) {
                r = noise222(rad, half2(20.6,100.6), half2(0.9,0.1));
            } else if (resolution < 0.005) {
                r = noise2(rad * 20.6);
            } else {
                r = noise2(rad * 10.3);
            }
            return r - 0.5;
        }

        static const half far = 10000.0;

        half3 snowflake_sdf_vector (
            half3 pos,
            half3 ray,
            half2 seed, half powr, half resolution
        ) {   
            const half zoom = 1.; // use this to change details. optimal 0.1 - 4.0.
            const half radius = 0.25; // above too much details
            const int iterations = 15;
            const half thickness = 0.0125;
            
            const half radius_sq = radius * radius;
            const half3 plane_normal = half3(0, 0, 1);
            
            const half invn = 1.0 / dot(plane_normal, ray);
            const half depthi = thickness * sign(invn);
            half ds = 2 * depthi * invn;

            half3 r1 = ray * (dot(plane_normal, pos) - depthi) * invn - pos;
            half3 r2 = r1 + ray * ds;

            const half len1 = length_sq(r1 + plane_normal * depthi);
            const half len2 = length_sq(r2 - plane_normal * depthi);
            
            const half3 n = normalize(cross(ray, plane_normal));
            const half mind = dot(pos, n);
            const half3 n2 = cross(ray, n);
            const half d = dot(n2, pos) / dot(n2, plane_normal);
            
            half3 distance_vector = ray * far;

            if (len1 < radius_sq || len2 < radius_sq || (abs(mind) < radius && abs(d) <= thickness)) {
                if (true && len1 >= radius_sq) {
                    half3 n3 = cross(plane_normal, n);
                    half a = rsqrt(radius_sq - mind * mind) * abs(dot(ray, n3));
                    half3 dt = ray / a;
                    r1 = -d * plane_normal - mind * n - dt;
                    if (len2 >= radius_sq) {
                        r2 = -d * plane_normal - mind * n + dt;
                    }
                    ds = dot(r2 - r1, ray);
                }
                ds = (abs(ds) + 0.1) / iterations;
                ds = lerp(thickness, ds, 0.2);
                ds = max(ds, 0.01);

                const half invd = 0.2 / thickness;
                const half ir = 0.35 / radius;
                radius *= zoom;
                ray = ray * ds * 5.0;

                for (int m = 0; m < iterations; m += 1) {
                    // Lobe construction
                    half l = length(r1.xy);
                    half2 c3 = abs(r1.xy / l);
                    if (c3.x > 0.5) {
                        c3 = abs(c3 * 0.5 + half2(-c3.y , c3.x) * 0.86602540);
                    }
                    //
                    half g = l + c3.x * c3.x;
                    l *= zoom;
                    half h = l - radius - 0.1;
                    l = pow(l, powr) + 0.1; // Changes form
                    h = max(h, lerp(lod_noise(c3 * l + seed, resolution), 1.0, abs(r1.z * invd))) + g * ir - 0.245; // Sample noise
                    if (h < resolution * 20.0 || abs(r1.z) > thickness + 0.01) {
                        break;
                    }
                    r1 += ray * h;
                    ray *= 0.99;
                }
                if (abs(r1.z) < thickness + 0.01) {
                    distance_vector = r1 + pos;
                }
            }
            return distance_vector;
        }

        half3 filterFlake (
            half3 color,
            half3 pos,
            half3 ray, half3 ray_dx, half3 ray_dy, // normalized
            half3 light,
            half2 seed, half resolution
        ) {
            const half3 ice_color = half3(0.0, 0.4, 1.0);

            half3 seedn = half3(seed, 1);
            half powr = noise3(seedn * 10.0) * 1.9 + 0.1;

            half3 distance_vector = snowflake_sdf_vector(pos, ray, seed, powr, resolution);
            if (length_sq(distance_vector) < far) {
                half3 distance_dx = snowflake_sdf_vector(pos, ray_dx, seed, powr, resolution);
                half3 distance_dy = snowflake_sdf_vector(pos, ray_dy, seed, powr, resolution);
                half3 snowflake_normal = normalize(cross(distance_dx - distance_vector, distance_dy - distance_vector));

                // lighting
                half abs_dot_normal_ray = abs(dot(snowflake_normal, ray));
                half da = pow(abs(dot(snowflake_normal, light)), 3.0);
                half3 cf = lerp(ice_color, color * 10.0, abs_dot_normal_ray);
                cf = lerp(cf, 2, da);
                color = lerp(color, cf, (0.5 + abs_dot_normal_ray * 0.5));
            } else {
                discard;
            }
            return color;
        }

        float3 tr(float3 v) {
            return mul(unity_WorldToObject, v);// mul(unity_MatrixInvV, v));
        }

        half4 fragment_stage (FragmentData input) : SV_Target {
            UNITY_SETUP_INSTANCE_ID(input);
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

            float2 inv_pixel_size = _ScreenParams.zw - 1;
            float resolution = min(inv_pixel_size.x, inv_pixel_size.y);

            // Build 2d coord in [-1,1]
            float2 p = input.uv0 * 2 - 1;
            
            //float3 pos = normalize(input.camera_os);
            //float3 ray = normalize(input.camera_to_geometry_os);
            float3 pos = float3(0, 0, 1); // noisespace ?                    
            float3 ray = float3(p, 2.0);
            float3 ray_dx = normalize(ray + float3(0, resolution * 2, 0)); // bad
            float3 ray_dy = normalize(ray + float3(resolution * 2, 0, 0));
            ray = normalize(ray);
            
            float3 light = normalize(float3(1, 0, 1));

            half3 color = filterFlake(
                half3(0, 0, 0), // current color
                tr(pos),
                tr(ray), tr(ray_dx), tr(ray_dy),
                light,
                input.snowflake_seed,
                resolution
            );
            return half4(color, 1);
        }

        ENDCG
    }
}
}
