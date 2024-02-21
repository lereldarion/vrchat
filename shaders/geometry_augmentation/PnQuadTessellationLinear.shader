// Goal : tessellate only to useful places : curved, on the side, large.
// Use PN quads to smooth geometry. Less artifacts than triangles.

// TODO modularize to reuse pn in shadowcaster
// TODO use real lighting, standard or something else

// Useful links :
// https://www.cise.ufl.edu/research/SurfLab/papers/1008PNquad.pdf
// Tessellation introduction https://nedmakesgames.medium.com/mastering-tessellation-shaders-and-their-many-uses-in-unity-9caeb760150e
// Tessellation factor semantics, useful for quads : https://www.reedbeta.com/blog/tess-quick-ref/
// Projection matrices https://jsantell.com/3d-projection/
// Archived reference https://microsoft.github.io/DirectX-Specs/d3d/archive/D3D11_3_FunctionalSpec.htm#HullShader
// Good practices from nvidia https://developer.download.nvidia.com/whitepapers/2010/PN-AEN-Triangles-Whitepaper.pdf

// PN strategy, for an edge :
// Edge P0P1 with normals n0 n1, and t barycentric coordinate (t=0 -> p0, t=1 -> p1)
// p0 ------- p1 -> t
//  \         /
//  n0       n1
//
// PN patch is a 3rd degree bezier : P(u, v) = sum_{0 <= i,j <= 3} b_ij C(i, 3) (1-u)^(3-i) u^i C(j, 3) (1-v)^(3-j) v^j
// With b_ij = Pi + 1/3 ((Pj - Pi) - dot (Pj - Pi, ni) ni)
// On the 01 edge : P(t) = P0 (1-t)^3 + 3 b01 (1-t)^2 t + 3 b10 (1-t) t^2 + t^3 P1
// Linear interpolation : I(t) = (1 - t) P0 + t P1.
// Error E(t) = P(t)-I(t) = (1-t)t [(1-t) dot(P0 - P1, n0) n0 + t dot(P1 - P0, n1) n1 ]
//
// Compared to phong, we cannot split displacement vector from displacement factor.
// Projection must be integrated before computing the maximum error.
// c__________p
//           /|
//          E Ep = project(E on cp) on plane tangent to cp = "camera distance to edge" (in practice edge center).
// Criterion is "max" theta = angle(p-c, Ep) ~ tan(angle) = length(Ep) / length (p - c)
// project(v on cp) = v - dot(v, cp/length(cp)) cp/length(cp) = v - dot(v, cp) cp / cp^2 ; a linear operator for constant cp
// So the final error criterion to estimate is (using the square to simplify things) :
// theta(t)^2 = Ep^2 / cp^2 = (1-t)^2 t^2 [(1-t) v0 + t v1]^2, with v0 v1 constant vectors, v0 = dot(P0 - P1, n0) project(n0 on cp) / length(cp)
//
// We want to estimate the "caracteristic" size of theta^2.
// max is annoying due to the need to solve a 3rd degree polynomial to find extremums.
// Instead we use avg of squared norm along the edge : int_0^1 theta(t)^2 dt / 1
//
// Anguler error estimation for n levels of tessellation :
// avg_theta_n^2 = sum_{0 <= k < n} int_{k/n <= t <= (k+1)/n} theta_kn(t)^2 dt
// With theta_kn(t) = length(project(E_kn(t) on cp)) / cp, with E_kn(t) = P(t) - I_kn(t), I_kn(t) interpolation between P(k/n) and P((k+1)/n).
// We can show that E_kn(t) = E(t) - [E(k/n)(1 - n(t-k/n)) + E((k+1)/n) n(t-k/n)]. I(t) simplifies out, and then we can apply the linear projection.
// Using wolfram alpha to reduce and simplify the expression for avg_theta_kn^2, with v0 and v1 from before :
// avg_theta_n^2 = [7n^2 (v0^2 - dot(v0, v1) + v1^2) - 5(v0 - v1)^2] / 210 n^6
//
// Finally we need to solve argmin_n avg_theta_n(n) <= error_target.
// The polynom correctly models that an edge with inflexion would not benefit much from n=2 and only start to decrease for n=3 onwards.
// Sadly non integer values do not make sense ; avg_theta_n(1.5) > max(avg_theta_n(1), avg_theta_n(2)).
// Directly solving the polynomial is non-sensical (in addition to being hard for 3-rd degree).
// Current strategy is to iterate on n=2^k until we find an ok value.
// Due to the criterion being an error average, we may have to increase target precision ?

// The current system uses angular size of D01 on the screen.
// This has similar quality, is cheaper to compute, and singularity is only a point.
// Angular precision is inferred to reach 1 pixel at screen center.

Shader "Lereldarion/Tessellation/PnQuadLinear"
{
    Properties {
        [Header (Standard Shader Parameters)]
        _Color ("Color", Color) = (1,1,1,1)
        _MainTexture ("Albedo (RGB)", 2D) = "white" {}

        [Header (Tessellation)]
        [Toggle (_TSL_PN_NORMALS_IN_VERTEX_COLOR)] _TSL_PN_Normals_In_Vertex_Color ("Use normals in vertex Color", Float) = 0
        _Precision_Pixel ("Precision in pixels", Range(1, 256)) = 1
        [ToggleUI] _Show_Wireframe ("Show Wireframe", Float) = 0
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
            #pragma shader_feature_local _TSL_PN_NORMALS_IN_VERTEX_COLOR

            #pragma vertex vertex_stage
            #pragma hull hull_control_point_stage
            #pragma domain domain_stage
            #pragma geometry geometry_stage
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
                #if _TSL_PN_NORMALS_IN_VERTEX_COLOR
                float3 pn_normal_encoded_os : COLOR;
                #endif
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationVertexData {
                float3 position_ws : CP_POSITION;
                float3 normal_ws : NORMAL; // non normalized
                float2 uv : TEXCOORD0;

                #if _TSL_PN_NORMALS_IN_VERTEX_COLOR
                float3 pn_normal_ws : NORMAL1;
                #else
                #define pn_normal_ws normal_ws
                #endif

                bool is_culled : CULLING_STATUS; // Early culling test (before tessellation) combines per-vertex values computed here

                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationControlPoint {
                TessellationVertexData vertex;
                // Compute edge-related data in parallel, for edge(vertex[i], vertex[i+1 mod 4])
                float edge_factor : EDGE_TESSELLATION_FACTOR;
                float3 d01_ws : EDGE_D01; // dot(P0 - P1, n0) n0
                float3 d10_ws : EDGE_D10; // dot(P1 - P0, n1) n1
            };

            struct TessellationFactors {
                float edge[4] : SV_TessFactor; // Edge association [u=0, v=0, u=1, v=1]
                float inside[2] : SV_InsideTessFactor; // Axis [u,v]
                // Vertex ordering is thus chosen as [(0, 1), (0, 0), (1, 0), (1, 1)] in (u,v coordinates)
                // v             e3
                // ↑  b0  -- b03 -- b30 -- b3
                //    b01 ---------------- b32 e2
                // e0 b10 ---------------- b23
                //    b1  -- b12 -- b21 -- b2
                //               e1            -> u
            };

            struct Interpolators {
                float4 pos : SV_POSITION; // CS, name required by stupid TRANSFER_SHADOW macro
                float2 uv : TEXCOORD0;

                // For WF pass
                float3 camera_to_position_ws : CAMERA_TO_POSITION_WS;
                float4 wireframe_distance_to_edge : WF_DISTANCE_TO_EDGE;

                fixed3 diffuse : COLOR0;
                fixed3 ambient : COLOR1;
                SHADOW_COORDS(2)

                UNITY_VERTEX_OUTPUT_STEREO
            };

            // Constants

            uniform fixed4 _Color;
            UNITY_DECLARE_TEX2D (_MainTexture);
            uniform float4 _MainTexture_ST; uniform float4 _MainTexture_TexelSize;

            uniform float _Precision_Pixel;
            uniform bool _Show_Wireframe;

            // stages

            bool in_frustum (float4 position_cs) {
                // pos.xyz/pos.w in cube (-1, -1, -1)*(1,1,1)
                float w = position_cs.w * 1.3; // Tolerance
                return all (abs (position_cs.xyz) <= abs (w));
            }
            bool surface_faces_camera (float3 position_ws, float3 normal_ws) {
                return dot (normal_ws, position_ws - _WorldSpaceCameraPos) < 0;
            }
            float norm2 (float3 v) { return dot (v, v); }

            TessellationVertexData vertex_stage (const VertexData input) {
                TessellationVertexData output;

                UNITY_SETUP_INSTANCE_ID (input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);

                output.position_ws = mul (unity_ObjectToWorld, float4 (input.position_os, 1));
                output.normal_ws = UnityObjectToWorldNormal (input.normal_os);
                output.uv = TRANSFORM_TEX (input.uv, _MainTexture);

                #if _TSL_PN_NORMALS_IN_VERTEX_COLOR
                output.pn_normal_ws = UnityObjectToWorldNormal (input.pn_normal_encoded_os * 2. - 1.);
                #endif

                output.is_culled = !surface_faces_camera (output.position_ws, output.normal_ws) || !in_frustum (UnityWorldToClipPos (output.position_ws));
                return output;
            }

            float3 camera_ws() {
                #if UNITY_SINGLE_PASS_STEREO
                return 0.5 * (unity_StereoWorldSpaceCameraPos[0] + unity_StereoWorldSpaceCameraPos[1]); // Avoid eye inconsistency, take center;
                #else
                return _WorldSpaceCameraPos;
                #endif
            }

            [domain ("quad")]
            [outputcontrolpoints (4)]
            [outputtopology ("triangle_cw")]
            [patchconstantfunc ("hull_patch_constant_stage")]
            [partitioning ("integer")]
            TessellationControlPoint hull_control_point_stage (const InputPatch<TessellationVertexData, 4> vertex, uint id0 : SV_OutputControlPointID) {
                TessellationControlPoint output;
                const TessellationVertexData v0 = vertex[id0];
                UNITY_SETUP_INSTANCE_ID (v0);
                output.vertex = v0;

                // Compute edge values in parallel
                uint id1 = id0 < 3 ? id0 + 1 : 0; // (id0 + 1) mod 4
                const TessellationVertexData v1 = vertex[id1];

                // Bezier control points along i,i+1 edge
                float3 p0p1_ws = v1.position_ws - v0.position_ws;
                output.d01_ws = dot (-p0p1_ws, v0.pn_normal_ws) * v0.pn_normal_ws;
                output.d10_ws = dot (p0p1_ws, v1.pn_normal_ws) * v1.pn_normal_ws;

                // camera --z-- 0 <- center of screen
                //        `a--- x <- x world space coord, target is pixel_precision px on the screen
                // World space angle a small => sin a = tan a = a = x / z = angle_precision
                #if UNITY_SINGLE_PASS_STEREO
                float2 screen_pixel_size = _ScreenParams.xy * unity_StereoScaleOffset[unity_StereoEyeIndex].xy;
                #else
                float2 screen_pixel_size = _ScreenParams.xy;
                #endif
                float2 tan_screen_angular_size = unity_CameraProjection._m00_m11; // View angles for camera https://jsantell.com/3d-projection/#projection-symmetry ; positive
                float2 screen_angular_size = tan_screen_angular_size; // approximation
                float2 pixel_angular_size = screen_angular_size / screen_pixel_size;
                float min_pixel_angular_size = min(pixel_angular_size.x, pixel_angular_size.y); // use highest resolution as threshold
                float angular_precision = min_pixel_angular_size * _Precision_Pixel;

                // Tessellation factor
                float3 eye_dir_ws = 0.5 * (v0.position_ws + v1.position_ws) - camera_ws();
                float inv_eye_dist2 = 1. / norm2 (eye_dir_ws);

                float3 d01_proj = output.d01_ws - inv_eye_dist2 * dot (output.d01_ws, eye_dir_ws) * eye_dir_ws;
                float3 d10_proj = output.d10_ws - inv_eye_dist2 * dot (output.d10_ws, eye_dir_ws) * eye_dir_ws;

                float inv_error_target2 = inv_eye_dist2 / (angular_precision * angular_precision);
                float polynom_coeff_2 = (7. / 210.) * (norm2 (d01_proj) - dot (d01_proj, d10_proj) + norm2 (d10_proj)) * inv_error_target2;
                float polynom_coeff_0 = (-5. / 210.) * norm2 (d01_proj - d10_proj) * inv_error_target2;

                float n = 1;
                float n6 = 1;
                while (n <= 63 && ((n * n) * polynom_coeff_2 + polynom_coeff_0) > n6) {
                    n *= 2;
                    n6 *= 64; // 2^6
                }

                output.edge_factor = n;
                return output;
            }

            TessellationFactors hull_patch_constant_stage (const OutputPatch<TessellationControlPoint, 4> cp) {
                TessellationFactors factors;
                
                if (cp[0].vertex.is_culled && cp[1].vertex.is_culled && cp[2].vertex.is_culled && cp[3].vertex.is_culled) {
                    // Early culling : discard quads entirely out of frustum or facing backwards
                    factors = (TessellationFactors) 0;
                } else {
                    [unroll] for (uint i = 0; i < 4; ++i) {
                        factors.edge[i] = cp[i].edge_factor;
                    }
                    factors.inside[0] = max (cp[1].edge_factor, cp[3].edge_factor);
                    factors.inside[1] = max (cp[0].edge_factor, cp[2].edge_factor);
                }
                return factors;
            }

            [domain ("quad")]
            Interpolators domain_stage (const TessellationFactors factors, const OutputPatch<TessellationControlPoint, 4> cp, float2 uv : SV_DomainLocation) {
                Interpolators output;

                UNITY_SETUP_INSTANCE_ID (cp[0].vertex);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                float4 muv_uv = float4 (1. - uv, uv);
                float4 cp_uv = muv_uv.xxzz * muv_uv.wyyw;
                #define UV_BARYCENTER(cp, accessor) (cp_uv[0] * (cp[0] accessor) + cp_uv[1] * (cp[1] accessor) + cp_uv[2] * (cp[2] accessor) + cp_uv[3] * (cp[3] accessor))

                // PN vertex displacement, using linear interpolate between bezier displacement on edges
                float2 umu_vmv = muv_uv.xy * muv_uv.zw;
                float4 c_vmv = umu_vmv.y * cp_uv;
                float4 c_umu = umu_vmv.x * cp_uv;
                float3 position_ws = UV_BARYCENTER (cp, .vertex.position_ws)
                + c_vmv[0] * cp[0].d01_ws + c_vmv[1] * cp[0].d10_ws + c_vmv[2] * cp[2].d01_ws + c_vmv[3] * cp[2].d10_ws
                + c_umu[0] * cp[3].d10_ws + c_umu[1] * cp[1].d01_ws + c_umu[2] * cp[1].d10_ws + c_umu[3] * cp[3].d01_ws;

                // Classic vertex stage transformations
                output.pos = UnityWorldToClipPos (position_ws);
                float3 normal_ws = normalize (UV_BARYCENTER (cp, .vertex.normal_ws)); // could do the quadratic version if motivated
                output.uv = UV_BARYCENTER (cp, .vertex.uv);

                // Wireframe data
                output.camera_to_position_ws = position_ws - camera_ws();
                output.wireframe_distance_to_edge = float4(0, 0, 0, 0); // Set later

                // Shading
                output.diffuse = max (0, dot (normal_ws, _WorldSpaceLightPos0.xyz)) * _LightColor0.rgb;
                output.ambient = ShadeSH9 (half4 (normal_ws, 1.));
                TRANSFER_SHADOW (output);

                return output;
            }

            [maxvertexcount(3)]
            void geometry_stage(triangle Interpolators i[3], inout TriangleStream<Interpolators> stream)
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i[0]);

                float2 p0 = i[0].pos.xy / i[0].pos.w;
                float2 p1 = i[1].pos.xy / i[1].pos.w;
                float2 p2 = i[2].pos.xy / i[2].pos.w;

                float2 edge0 = p2 - p1;
                float2 edge1 = p2 - p0;
                float2 edge2 = p1 - p0;

                // To find the distance to the opposite edge, we take the
                // formula for finding the area of a triangle Area = Base/2 * Height,
                // and solve for the Height = (Area * 2)/Base.
                // We can get the area of a triangle by taking its cross product
                // divided by 2.  However we can avoid dividing our area/base by 2
                // since our cross product will already be double our area.
                float area = abs(edge1.x * edge2.y - edge1.y * edge2.x);
                float wireThickness = 800;

                i[0].wireframe_distance_to_edge.xyz = float3( (area / length(edge0)), 0.0, 0.0) * i[0].pos.w * wireThickness;
                i[0].wireframe_distance_to_edge.w = 1.0 / i[0].pos.w;
                stream.Append(i[0]);

                i[1].wireframe_distance_to_edge.xyz = float3(0.0, (area / length(edge1)), 0.0) * i[1].pos.w * wireThickness;
                i[1].wireframe_distance_to_edge.w = 1.0 / i[1].pos.w;
                stream.Append(i[1]);

                i[2].wireframe_distance_to_edge.xyz = float3(0.0, 0.0, (area / length(edge2))) * i[2].pos.w * wireThickness;
                i[2].wireframe_distance_to_edge.w = 1.0 / i[2].pos.w;
                stream.Append(i[2]);
            }

            fixed4 fragment_stage (Interpolators input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX (input);

                // Basic lighting
                fixed4 albedo = UNITY_SAMPLE_TEX2D (_MainTexture, input.uv) * _Color;
                fixed4 color = albedo * fixed4 (input.diffuse * SHADOW_ATTENUATION (input) + input.ambient, 1.);

                // Wireframe
                float4 packed_dist = input.wireframe_distance_to_edge;
                float minDistanceToEdge = min(packed_dist[0], min(packed_dist[1], packed_dist[2])) * packed_dist[3];
                if (_Show_Wireframe && minDistanceToEdge < 0.9) {
                    float t = exp2(-2 * minDistanceToEdge * minDistanceToEdge);
                    float cameraToVertexDistance = length(input.camera_to_position_ws);
                    fixed4 wireColor = fixed4(0, 0, 0, 1);
                    color = lerp(color, wireColor, t);
                }
                return color;
            }

            ENDCG
        }
    }
}
