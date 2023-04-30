// Goal : tessellate only to useful places : curved, on the side, large.
// Use Phong to smooth geometry. Instead of triangles, use it on quads, it generates less artifacts.

// TODO modularize to reuse phong in shadowcaster
// TODO use real lighting, standard or something else

// Useful links :
// Quad phong tessellation https://liris.cnrs.fr/Documents/Liris-6161-phong_tess.pdf
// Tessellation introduction https://nedmakesgames.medium.com/mastering-tessellation-shaders-and-their-many-uses-in-unity-9caeb760150e
// Tessellation factor semantics, useful for quads : https://www.reedbeta.com/blog/tess-quick-ref/
// Projection matrices https://jsantell.com/3d-projection/
// Archived reference https://microsoft.github.io/DirectX-Specs/d3d/archive/D3D11_3_FunctionalSpec.htm#HullShader
// Good practices from nvidia https://developer.download.nvidia.com/whitepapers/2010/PN-AEN-Triangles-Whitepaper.pdf

// Phong strategy, for an edge :
// Edge P0P1 with normals n0 n1, and x barycentric coordinate (x=0 -> p0, x=1 -> p1)
// p0 ------- p1 -> x
//  \         /
//  n0       n1
// We assume p0 to be at the origin for simplicity.
//
// The phong interpolated curve can be rewritten as :
// P(x) = x P0P1 + x(1-x) D01, with D01 = dot(P0P1, n1) n1 - dot(P0P1, n0) n0
// Meanwhile the linear interpolation is I(x) = x P0P1
// The distance ("error") between edge and P is thus E(x) = x(1-x) D01
// The maximum is at x=0.5 (expected), with value max E = 0.25 D01
// This error vector can be projected onto whatever space is meaninful for creating a criteria, and Phong mixing factor added onto it.
//
// No we perform a tessellation of factor n, cutting the edge in n edges between points P(k/n) on the curve P.
// The k-th edge between P(k/n) and P((k+1)/n) has the following formula, for k/n <= x <= (k+1)/n :
// I^k(x) = x P0P1 + (x (1-(2k+1)/n) + k(k+1)/n^2) D01
// Thus the error vector is : E^k(x) = (-x^2 + x(2k+1)/n - k(k+1)/n^2) D01
// The maximum is at x = k/n + 1/(2n), again expected. Value is max E^k = 1/(4n^2) D01 !
// This is not dependent on k, and has a very simple form useful to choose n to match a requested precision.

// The last step is the precision metric, ie how to project D01 to "human perception precision".
//
// First idea was to project D01 in screenspace and target a 1 pixel precision :
//   float2 screen_position_z_clamped (float3 position_os) {
//       // Go to clip space, which is view space normalised in xy and with depth in w
//       float4 position_cs = ComputeScreenPos (UnityObjectToClipPos (position_os));
//       float near_plane = _ProjectionParams.y;
//       float depth = max (position_cs.w, near_plane); // Prevent spike in tessellation if depth is near focal point
//       return position_cs.xy / depth * _ScreenParams.xy;
//   }
//   float error_ss_length = distance (screen_position_z_clamped (center_p0p1_os), screen_position_z_clamped (max_phong_os));
//   float tessellation_level = sqrt (error_ss_length / pixel_precision);
// Good results but some spike in tessellation when projection ends up on the z=0 plane in view space.
//
// The current system uses angular size of D01 on the screen.
// This has similar quality, is cheaper to compute, and singularity is only a point.
// Angular precision is inferred to reach 1 pixel at screen center.

Shader "Lereldarion/Tessellation/PhongQuad"
{
    Properties {
        [Header (Standard Shader Parameters)]
        _Color ("Color", Color) = (1,1,1,1)
        _MainTexture ("Albedo (RGB)", 2D) = "white" {}

        [Header (Tessellation)]
        _TSL_Phong ("Phong coefficient", Range (0, 1)) = 0.5
        [Toggle (_TSL_PHONG_NORMALS_IN_VERTEX_COLOR)] _TSL_Phong_Normals_In_Vertex_Color ("Use normals in vertex Color", Float) = 0
    }
    SubShader {
        Tags {
            "RenderType" = "Opaque"
            "VRCFallback" = "Standard"
        }
        LOD 600

        Pass {
            Tags { "LightMode" = "ForwardBase" }

            CGPROGRAM
            #pragma target 5.0
            #pragma multi_compile_instancing
            #pragma shader_feature_local _TSL_PHONG_NORMALS_IN_VERTEX_COLOR

            #pragma vertex vertex_stage
            #pragma hull hull_control_point_stage
            #pragma domain domain_stage
            #pragma fragment fragment_stage

            #include "UnityCG.cginc"
            #include "UnityLightingCommon.cginc"

            // FIXME basic shadow handling
            #pragma multi_compile_fwdbase nolightmap nodirlightmap nodynlightmap novertexlight // compile shader into multiple variants, with and without shadows (skip lightmap variants)
            #include "AutoLight.cginc" // shadow helper functions and macros

            // Types

            struct VertexData {
                float3 position_os : POSITION;
                float3 normal_os : NORMAL;
                float2 uv : TEXCOORD0;
                #if _TSL_PHONG_NORMALS_IN_VERTEX_COLOR
                float3 phong_normal_encoded_os : COLOR;
                #endif
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationVertexData {
                float3 position_os : CP_POSITION;
                float3 normal_os : NORMAL;
                float2 uv : TEXCOORD0;

                #if _TSL_PHONG_NORMALS_IN_VERTEX_COLOR
                float3 phong_normal_os : NORMAL1;
                #else
                #define phong_normal_os normal_os
                #endif

                bool is_culled : CULLING_STATUS; // Early culling test (before tessellation) combines per-vertex values computed here

                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationControlPoint {
                TessellationVertexData vertex;
                // Compute edge-related data in parallel, for edge(vertex[i], vertex[i+1 mod 4])
                float edge_factor : EDGE_TESSELLATION_FACTOR;
            };

            struct TessellationFactors {
                float edge[4] : SV_TessFactor; // Edge association [u=0, v=0, u=1, v=1]
                float inside[2] : SV_InsideTessFactor; // Axis [u,v]
                // Vertex ordering is thus chosen as [(0, 1), (0, 0), (1, 0), (1, 1)] in (u,v coordinates)
            };

            struct Interpolators {
                float4 pos : SV_POSITION; // CS, name required by stupid TRANSFER_SHADOW macro
                float2 uv : TEXCOORD0;

                fixed3 diffuse : COLOR0;
                fixed3 ambient : COLOR1;
                SHADOW_COORDS(2)

                UNITY_VERTEX_OUTPUT_STEREO
            };

            // Constants

            UNITY_DECLARE_TEX2D (_MainTexture);
            uniform float4 _MainTexture_ST; uniform float4 _MainTexture_TexelSize;

            uniform fixed4 _Color;

            uniform float _TSL_Phong;

            static const float pixel_precision = 1;

            // stages

            static float3 camera_os = mul (unity_WorldToObject, float4 (_WorldSpaceCameraPos, 1)).xyz;

            bool in_frustum (float4 position_cs) {
                // pos.xyz/pos.w in cube (-1, -1, -1)*(1,1,1)
                float w = position_cs.w * 1.3; // Tolerance
                return all (abs (position_cs.xyz) <= abs (w));
            }
            bool surface_faces_camera (const VertexData vertex) {
                return dot (vertex.normal_os, vertex.position_os - camera_os) < 0;
            }

            TessellationVertexData vertex_stage (const VertexData input) {
                TessellationVertexData output;

                UNITY_SETUP_INSTANCE_ID (input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);

                output.position_os = input.position_os;
                output.normal_os = input.normal_os;
                output.uv = TRANSFORM_TEX (input.uv, _MainTexture);

                #if _TSL_PHONG_NORMALS_IN_VERTEX_COLOR
                output.phong_normal_os = input.phong_normal_encoded_os * 2. - 1.;
                #endif

                output.is_culled = !surface_faces_camera (input) || !in_frustum (UnityObjectToClipPos (input.position_os));
                return output;
            }

            float edge_tessellation_factor (const TessellationVertexData p0, const TessellationVertexData p1) {
                float3 p0p1_os = p1.position_os - p0.position_os;
                float3 d01_os = dot (p0p1_os, p1.phong_normal_os) * p1.phong_normal_os - dot (p0p1_os, p0.phong_normal_os) * p0.phong_normal_os;
                float3 center_p0p1_os = 0.5 * (p0.position_os + p1.position_os);

                // Measure angular size of max phong displacement from camera viewpoint.
                // Easier in view space, but world space is cheaper. World to view space should have uniform scaling.
                float3 eye_to_center_p0p1_ws = mul (unity_ObjectToWorld, float4 (center_p0p1_os, 1)).xyz - _WorldSpaceCameraPos;
                float3 max_phong_ws = mul ((float3x3) unity_ObjectToWorld, 0.25 * _TSL_Phong * d01_os); // Vector, not position, so ignore translations

                // Approximate angle by using tan(angle) = |max_phong projected on eye dir plane| / eye_distance
                // A previous strategy was to use cross(eye_dir_to_a, eye_dir_to_b) to compute sin of angle, but this was 10% more math cost.
                float inv_ec2 = 1. / dot (eye_to_center_p0p1_ws, eye_to_center_p0p1_ws);
                float3 max_phong_proj_ws = max_phong_ws - (inv_ec2 * dot (max_phong_ws, eye_to_center_p0p1_ws)) * eye_to_center_p0p1_ws;
                float abs_tan_angle = sqrt (dot (max_phong_proj_ws, max_phong_proj_ws) * inv_ec2);

                // camera --z-- 0 <- center of screen
                //        `a--- x <- x world space coord, target is pixel_precision px on the screen
                // World space angle a small => sin a = tan a = a = x / z = angle_precision
                // Projection + divide + ComputeScreenPos(uv) + to_pixel : x * proj[0][0] * (1 / z) * (0.5 * unity_StereoScaleOffset.x) * ScreenParams.x = pixel_precision
                #if UNITY_SINGLE_PASS_STEREO
                float scale_offset = unity_StereoScaleOffset[unity_StereoEyeIndex].x;
                #else
                float scale_offset = 1;
                #endif
                float inv_angle_precision = unity_CameraProjection[0][0] * 0.5 * scale_offset * _ScreenParams.x / pixel_precision;

                float tessellation_level = sqrt (abs_tan_angle * inv_angle_precision);

                return clamp (tessellation_level, 1, 64);
            }

            [domain ("quad")]
            [outputcontrolpoints (4)]
            [outputtopology ("triangle_cw")]
            [patchconstantfunc ("hull_patch_constant_stage")]
            [partitioning ("integer")]
            TessellationControlPoint hull_control_point_stage (const InputPatch<TessellationVertexData, 4> vertex, uint id0 : SV_OutputControlPointID) {
                TessellationControlPoint output;
                output.vertex = vertex[id0];

                // Compute additional edge values in parallel
                uint id1 = id0 < 3 ? id0 + 1 : 0; // (id0 + 1) mod 4
                output.edge_factor = edge_tessellation_factor (vertex[id0], vertex[id1]); 
                return output;
            }

            TessellationFactors hull_patch_constant_stage (const OutputPatch<TessellationControlPoint, 4> cp) {
                TessellationFactors factors;
                
                if (cp[0].vertex.is_culled && cp[1].vertex.is_culled && cp[2].vertex.is_culled && cp[3].vertex.is_culled) {
                    // Early culling : discard quads entirely out of frustum or facing backwards
                    factors = (TessellationFactors) 0;
                } else {
                    [unroll] for (int i = 0; i < 4; ++i) {
                        factors.edge[i] = cp[i].edge_factor;
                    }
                    factors.inside[0] = max (cp[1].edge_factor, cp[3].edge_factor);
                    factors.inside[1] = max (cp[0].edge_factor, cp[2].edge_factor);
                }
                return factors;
            }

            #define UV_BARYCENTER(cp, accessor) lerp (lerp (cp[1] accessor, cp[2] accessor, uv.x), lerp (cp[0] accessor, cp[3] accessor, uv.x), uv.y)

            float3 phong_projection_displacement (float3 linear_interpolation_os, const TessellationVertexData p) {
                // Projection operator : pi(q, p_i, n) = q - dot(q - p_i, n) n, but just extract the displacement
                return dot (p.position_os - linear_interpolation_os, p.phong_normal_os) * p.phong_normal_os;
            }

            [domain ("quad")]
            Interpolators domain_stage (const TessellationFactors factors, const OutputPatch<TessellationControlPoint, 4> cp, float2 uv : SV_DomainLocation) {
                Interpolators output;

                UNITY_SETUP_INSTANCE_ID (cp[0].vertex);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                // Phong vertex displacement
                float3 linear_interpolation_os = UV_BARYCENTER (cp, .vertex.position_os);
                float3 phong_displacements[4];
                [unroll] for (int i = 0; i < 4; ++i) {
                    phong_displacements[i] = phong_projection_displacement (linear_interpolation_os, cp[i].vertex);
                }
                float3 phong_displacement = UV_BARYCENTER (phong_displacements, +0);
                float3 position_os = linear_interpolation_os + _TSL_Phong * phong_displacement;

                // Classic vertex stage transformations
                output.pos = UnityObjectToClipPos (position_os);
                float3 normal_os = UV_BARYCENTER (cp, .vertex.normal_os);
                output.uv = UV_BARYCENTER (cp, .vertex.uv);

                // Shading
                float3 normal_ws = UnityObjectToWorldNormal (normal_os);
                output.diffuse = max (0, dot (normal_ws, _WorldSpaceLightPos0.xyz)) * _LightColor0.rgb;
                output.ambient = ShadeSH9 (half4 (normal_ws, 1.));
                TRANSFER_SHADOW (output);

                return output;
            }

            fixed4 fragment_stage (Interpolators input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX (input);

                // TODO lighting
                fixed4 albedo = UNITY_SAMPLE_TEX2D (_MainTexture, input.uv) * _Color;
                return albedo * fixed4 (input.diffuse * SHADOW_ATTENUATION (input) + input.ambient, 1.);
            }

            ENDCG
        }

    }
    
    Fallback "Diffuse" // FIXME use tesselation with lesser precision criteria ?
}
