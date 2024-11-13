// Goal : tessellate only to useful places : curved, on the side, large.
// Use PN quads to smooth geometry. Less artifacts than triangles.

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
// Displacement D(t) = P(t)-I(t) = (1-t)t [(1-t) dot(P0 - P1, n0) n0 + t dot(P1 - P0, n1) n1 ]

Shader "Lereldarion/Procedural Ruffles" {
    Properties {
        [Header (Standard Shader Parameters)]
        _Color ("Color", Color) = (1,1,1,1)

        [Header (Ruffling)]
        _Ruffle_Cycles ("Cycle count over uv=[0,1]", Float) = 10
        _Ruffle_Thickness ("Thickness", Float) = 0.01
        _Ruffle_Width ("Width", Float) = 0.01

        [Header (Tessellation)]
        _Ruffle_Tessellation_Half_Cycle ("Tessellation per half cycle", Integer) = 0
        _Ruffle_Tessellation_Y ("Tessellation Y", Integer) = 1
    }
    SubShader {
        Tags {
            "RenderType" = "Opaque"
            "VRCFallback" = "Standard"
        }

        Pass {
            Tags { "LightMode" = "ForwardBase" }

            Cull Off

            CGPROGRAM
// Upgrade NOTE: excluded shader from OpenGL ES 2.0 because it uses non-square matrices
#pragma exclude_renderers gles
            #pragma target 5.0
            #pragma multi_compile_instancing
            #pragma multi_compile_fwdbase nolightmap nodirlightmap nodynlightmap novertexlight // compile shader into multiple variants, with and without shadows (skip lightmap variants)

            #pragma vertex true_vertex_stage
            #pragma hull hull_control_point_stage
            #pragma domain domain_stage
            #pragma fragment fragment_stage

            #include "UnityCG.cginc"
            #include "UnityLightingCommon.cginc"
            #include "AutoLight.cginc" // shadow helper functions and macros

            ///////////////////////////////////////////////////////////////////
            // Normal vertex and fragment, that will be used within tessellation later

            struct VertexData {
                float3 position_os : POSITION_OS;
                float3 normal_os : NORMAL_OS;
                float3 tangent_os : TANGENT_OS;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID // Setup has been called
            };

            struct FragmentData {
                float4 pos : SV_POSITION; // CS, name required by stupid TRANSFER_SHADOW macro
                float2 uv : TEXCOORD0;

                fixed3 diffuse : DIFFUSE;
                fixed3 ambient : AMBIENT;
                SHADOW_COORDS(1)

                UNITY_VERTEX_OUTPUT_STEREO
            };

            void vertex_stage(const VertexData input, out FragmentData output) {                
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                output.pos = UnityObjectToClipPos (input.position_os);
                output.uv = input.uv;

                // Basic lighting
                float3 normal_ws = UnityObjectToWorldNormal(input.normal_os);
                output.diffuse = max (0, dot (normal_ws, _WorldSpaceLightPos0.xyz)) * _LightColor0.rgb;
                output.ambient = ShadeSH9 (half4 (normal_ws, 1.));
                TRANSFER_SHADOW (output);
            }

            uniform fixed4 _Color;

            fixed4 fragment_stage(FragmentData input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX (input);

                // Basic lighting
                fixed4 color = _Color * fixed4(input.uv, 0, 1);
                return color * fixed4 (input.diffuse * SHADOW_ATTENUATION (input) + input.ambient, 1.);
            }

            ///////////////////////////////////////////////////////////////////

            struct TrueVertexData {
                float3 position_os : POSITION;
                float3 normal_os : NORMAL; // May be non-normalized due to skinning

                float2 uv : TEXCOORD0; // Used to guide ruffles : X = direction along ruffles 01, Y = from flat to thick on a ruffle 01.
                // TODO secondary uv to configure thickness & loop count
                
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationVertexData {
                float3 position_os : POSITION_OS;
                float3 normal_os : NORMAL_OS; // Normalized
                float normal_length : NORMAL_LENGTH;
                float2 uv : TEXCOORD0;

                // X : ruffle extremum index from 0 to 2 * ruffle_count
                // Y : thickness track 01
                float2 ruffle_uv : RUFFLE_UV;

                //bool is_culled : CULLING_STATUS; // Early culling test (before tessellation) combines per-vertex values computed here

                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationControlPoint {
                TessellationVertexData vertex;

                // Pn displacement towards edges along patch u and v
                float3 pn_d_edge_u : PN_DISPLACEMENT_EDGE_U; // dot(P - Pu, n) n
                float3 pn_d_edge_v : PN_DISPLACEMENT_EDGE_V; // dot(P - Pv, n) n
            };

            struct TessellationFactors {
                // Subdivision factors related to patch_uv
                float edge[4] : SV_TessFactor; // Subdivide along edges [u=0, v=0, u=1, v=1]
                float inside[2] : SV_InsideTessFactor; // Subdivide interior along axis [u, v] ; 0 = e1/e3, 1 = e0/e2

                // Vertex patch_uv association is chosen as [(0, 0), (1, 0), (1, 1), (0, 1)]
                // v             e3
                // ↑  b3  -- b32 -- b23 -- b2
                //    b30 ---------------- b21 e2
                // e0 b03 ---------------- b12
                //    b0  -- b01 -- b10 -- b1
                //               e1            -> u
            };

            // Constants

            uniform float _Ruffle_Cycles;
            uniform float _Ruffle_Thickness;
            uniform float _Ruffle_Width;

            uniform uint _Ruffle_Tessellation_Half_Cycle; // Edges per half loop
            uniform uint _Ruffle_Tessellation_Y;

            // stages

            bool in_frustum (float4 position_cs) {
                // pos.xyz/pos.w in cube (-1, -1, -1)*(1,1,1)
                float w = position_cs.w * 1.3; // Tolerance
                return all (abs (position_cs.xyz) <= abs (w));
            }
            bool surface_faces_camera (float3 position_ws, float3 normal_ws) {
                return dot (normal_ws, position_ws - _WorldSpaceCameraPos) < 0.0;
            }
            float length_sq (float3 v) { return dot (v, v); }

            float pixel_angular_size() {
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
                return min(pixel_angular_size.x, pixel_angular_size.y); // use highest resolution as threshold
            }

            float3 centered_camera_ws() {
                #if UNITY_SINGLE_PASS_STEREO
                return 0.5 * (unity_StereoWorldSpaceCameraPos[0] + unity_StereoWorldSpaceCameraPos[1]); // Avoid eye inconsistency, take center;
                #else
                return _WorldSpaceCameraPos;
                #endif
            }

            void true_vertex_stage (const TrueVertexData input, out TessellationVertexData output) {
                UNITY_SETUP_INSTANCE_ID (input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);

                output.position_os = input.position_os.xyz;
                output.normal_length = length(input.normal_os); // Length useful to adjust ruffle thickness with skinning+scaling
                output.normal_os = input.normal_os / output.normal_length; // Might as well with the length
                output.uv = input.uv;

                output.ruffle_uv = float2(
                    round(2.0 * _Ruffle_Cycles * input.uv.x), // [0, 2N], integer. a ruffle takes 2 indexes (up down up)
                    input.uv.y
                );

                //output.is_culled = !surface_faces_camera (output.position_ws, output.normal_ws) || !in_frustum (UnityWorldToClipPos (output.position_ws));
            }

            uint rotation_to_align_patch_with_ruffle(const InputPatch<TessellationVertexData, 4> inputs, uint id) {
                // Rotate patch to ensure ruffle_uv and patch_uv are aligned.
                // Align ruffle_uv.y positive slope with patch_uv +Y.
                // ruffle_uv.x slope is dependent on mesh orientation, so it cannot be fixed here.
                float2 current_patch_delta_ruffle_y = float2(
                    (inputs[1].ruffle_uv.y + inputs[2].ruffle_uv.y) - (inputs[0].ruffle_uv.y + inputs[3].ruffle_uv.y), // u
                    (inputs[2].ruffle_uv.y + inputs[3].ruffle_uv.y) - (inputs[0].ruffle_uv.y + inputs[1].ruffle_uv.y)  // v
                );
                // 4 rotations depending on ruffle_uv.y slope orientation
                [flatten]
                if (abs(current_patch_delta_ruffle_y.y) >= abs(current_patch_delta_ruffle_y.x)) {
                    if (current_patch_delta_ruffle_y.y >= 0) {
                        return 0; // Slope is +Y
                    } else {
                        return 2; // Slope is -Y, rotate 180
                    }
                } else {
                    if (current_patch_delta_ruffle_y.x >= 0) {
                        return 3; // Slope is +X, rotate 270 to return b3 as b0
                    } else {
                        return 1; // Slope is -X, rotate 90 to return b1 as b0
                    }
                }
            }

            [domain ("quad")]
            [outputcontrolpoints (4)]
            [outputtopology ("triangle_cw")]
            [patchconstantfunc ("hull_patch_constant_stage")]
            [partitioning ("integer")]
            //[maxtessfactor (64.)]
            TessellationControlPoint hull_control_point_stage (const InputPatch<TessellationVertexData, 4> inputs, uint id : SV_OutputControlPointID) {
                uint rotation = rotation_to_align_patch_with_ruffle(inputs, id);
                id = (id + rotation) % 4;
                
                TessellationControlPoint output;
                
                const TessellationVertexData input = inputs[id];
                UNITY_SETUP_INSTANCE_ID (input);
                output.vertex = input;
                
                // Displacement for edge u/v from this patch corner. Use xor to get the other point ids.
                bool swaps_axis = rotation & 1 == 1;
                output.pn_d_edge_u = dot(input.position_os - inputs[id ^ (swaps_axis ? 3 : 1)].position_os, input.normal_os) * input.normal_os;
                output.pn_d_edge_v = dot(input.position_os - inputs[id ^ (swaps_axis ? 1 : 3)].position_os, input.normal_os) * input.normal_os;
                
                return output;
            }

            void hull_patch_constant_stage (const OutputPatch<TessellationControlPoint, 4> cp, out TessellationFactors factors) {
                float half_cycle_count = abs(cp[2].vertex.ruffle_uv.x - cp[3].vertex.ruffle_uv.x);
                float tessellation_x = half_cycle_count * _Ruffle_Tessellation_Half_Cycle; // 0 -> 0, n -> per half cycle
                
                factors.inside[0] = factors.edge[1] = factors.edge[3] = tessellation_x;
                factors.inside[1] = factors.edge[0] = factors.edge[2] = _Ruffle_Tessellation_Y;
            }

            struct InterpolatedVertexData {
                float3 position;
                float3 tangent_u;
                float3 normal;
                float normal_length;
                float2 uv;
                float2 ruffle_uv;

                static InterpolatedVertexData interpolate(const OutputPatch<TessellationControlPoint, 4> cp, float2 patch_uv) {
                    float4 muv_uv = float4 (1.0 - patch_uv, patch_uv);
                    float2 umu_vmv = muv_uv.xy * muv_uv.zw;

                    float4 linear_cp_factor = muv_uv.xzzx * muv_uv.yyww;
                    float4 umu_factors = umu_vmv.x * linear_cp_factor;
                    float4 vmv_factors = umu_vmv.y * linear_cp_factor;

                    float4 dlinear_cp_factor_du = float4(-1, 1, 1, -1) * muv_uv.yyww;
                    float du2mu_du = (2.0 - 3.0 * patch_uv.x) * patch_uv.x;
                    float dmu2u_du = 1 + (-4 + 3.0 * patch_uv.x) * patch_uv.x;
                    float4 dumu_factors_du = float4(dmu2u_du, du2mu_du, du2mu_du, dmu2u_du) * muv_uv.yyww;
                    float4 dvmv_factors_du = umu_vmv.y * dlinear_cp_factor_du;

                    InterpolatedVertexData output;

                    // PN vertex displacement, using linear interpolate between bezier displacement on edges
                    output.position = (
                        linear_cp_factor[0] * cp[0].vertex.position_os +
                        linear_cp_factor[1] * cp[1].vertex.position_os +
                        linear_cp_factor[2] * cp[2].vertex.position_os +
                        linear_cp_factor[3] * cp[3].vertex.position_os +
                        umu_factors[0] * cp[0].pn_d_edge_u + umu_factors[1] * cp[1].pn_d_edge_u + umu_factors[2] * cp[2].pn_d_edge_u + umu_factors[3] * cp[3].pn_d_edge_u +
                        vmv_factors[0] * cp[0].pn_d_edge_v + vmv_factors[1] * cp[1].pn_d_edge_v + vmv_factors[2] * cp[2].pn_d_edge_v + vmv_factors[3] * cp[3].pn_d_edge_v
                    );               
                    // u tangent : derive position by u
                    output.tangent_u = normalize(
                        dlinear_cp_factor_du[0] * cp[0].vertex.position_os +
                        dlinear_cp_factor_du[1] * cp[1].vertex.position_os +
                        dlinear_cp_factor_du[2] * cp[2].vertex.position_os +
                        dlinear_cp_factor_du[3] * cp[3].vertex.position_os +
                        dumu_factors_du[0] * cp[0].pn_d_edge_u + dumu_factors_du[1] * cp[1].pn_d_edge_u + dumu_factors_du[2] * cp[2].pn_d_edge_u + dumu_factors_du[3] * cp[3].pn_d_edge_u +
                        dvmv_factors_du[0] * cp[0].pn_d_edge_v + dvmv_factors_du[1] * cp[1].pn_d_edge_v + dvmv_factors_du[2] * cp[2].pn_d_edge_v + dvmv_factors_du[3] * cp[3].pn_d_edge_v
                    );
                    // Normals : linear interpolation
                    output.normal = normalize(
                        linear_cp_factor[0] * cp[0].vertex.normal_os +
                        linear_cp_factor[1] * cp[1].vertex.normal_os +
                        linear_cp_factor[2] * cp[2].vertex.normal_os +
                        linear_cp_factor[3] * cp[3].vertex.normal_os
                    );
                    output.normal_length = (
                        linear_cp_factor[0] * cp[0].vertex.normal_length +
                        linear_cp_factor[1] * cp[1].vertex.normal_length +
                        linear_cp_factor[2] * cp[2].vertex.normal_length +
                        linear_cp_factor[3] * cp[3].vertex.normal_length
                    );
                    output.uv = (
                        linear_cp_factor[0] * cp[0].vertex.uv +
                        linear_cp_factor[1] * cp[1].vertex.uv +
                        linear_cp_factor[2] * cp[2].vertex.uv +
                        linear_cp_factor[3] * cp[3].vertex.uv
                    );
                    output.ruffle_uv = (
                        linear_cp_factor[0] * cp[0].vertex.ruffle_uv +
                        linear_cp_factor[1] * cp[1].vertex.ruffle_uv +
                        linear_cp_factor[2] * cp[2].vertex.ruffle_uv +
                        linear_cp_factor[3] * cp[3].vertex.ruffle_uv
                    );
                    return output;
                }
            };

            struct RuffleControlPoints {
                //      half_cycle            \
                //     /    |     \            | thickness
                // back     |      forward     |
                //      \   pn ---> ruffle_u  /
                // 2x th \  |\_____/
                //        \ |  width
                //          o
                float3 half_cycle;
                float3 back;
                float3 forward;

                static RuffleControlPoints compute(InterpolatedVertexData pn, float half_loop_range, bool half_cycle_is_pair) {
                    float half_thickness = 0.5 * _Ruffle_Thickness;
                    float half_width = 0.5 * _Ruffle_Width;
                    float lateral_thickness = sqrt(pow(_Ruffle_Thickness, 2.0) - pow(half_width, 2.0)) - half_thickness;

                    float3 scaled_normal = pn.normal * (half_cycle_is_pair ? 1.0 : -1.0) * pn.normal_length;
                    float3 lateral = pn.tangent_u * sign(half_loop_range) * pn.normal_length * half_width;

                    // From geometric figure

                    RuffleControlPoints cp;
                    cp.half_cycle = pn.position + scaled_normal * half_thickness;
                    cp.back = pn.position + scaled_normal * lateral_thickness - lateral;
                    cp.forward = pn.position + scaled_normal * lateral_thickness + lateral;
                    return cp;
                }
            };

            [domain ("quad")]
            void domain_stage (const TessellationFactors factors, const OutputPatch<TessellationControlPoint, 4> cp, float2 patch_uv : SV_DomainLocation, out FragmentData output) {
                UNITY_SETUP_INSTANCE_ID (cp[0].vertex);

                VertexData synthesized_input;
                UNITY_TRANSFER_INSTANCE_ID(cp[0].vertex, synthesized_input);
                
                InterpolatedVertexData pn = InterpolatedVertexData::interpolate(cp, patch_uv);

                // Half loop positionning
                float half_cycle = pn.ruffle_uv.x;
                float half_cycle_before = floor(half_cycle);
                float half_cycle_after = half_cycle_before + 1.0;
                float offset_01_within_half_cycle = frac(half_cycle);
                float offset_03_within_half_cycle = 3.0 * offset_01_within_half_cycle;
                float spline_segment_within_half_cycle = floor(offset_03_within_half_cycle); // 0 1 2
                float offset_within_spline_segment = frac(offset_03_within_half_cycle);

                // Sample PN surface at neighboring half loop extremities
                float2 patch_uv_half_loop_before = patch_uv;
                float2 patch_uv_half_loop_after = patch_uv;
                float half_loop_range = cp[2].vertex.ruffle_uv.x - cp[3].vertex.ruffle_uv.x;
                //if(half_loop_range == 0.0) { half_loop_range = 1.0; }
                patch_uv_half_loop_before.x = (half_cycle_before - cp[3].vertex.ruffle_uv.x) / half_loop_range;
                patch_uv_half_loop_after.x = (half_cycle_after - cp[3].vertex.ruffle_uv.x) / half_loop_range;
                InterpolatedVertexData pn_half_cycle_before = InterpolatedVertexData::interpolate(cp, patch_uv_half_loop_before);
                InterpolatedVertexData pn_half_cycle_after = InterpolatedVertexData::interpolate(cp, patch_uv_half_loop_after);

                // Use them and tangent to create b spline control points
                bool hc_before_is_pair = frac(0.5 * half_cycle_before) < 0.25;
                RuffleControlPoints cp_before = RuffleControlPoints::compute(pn_half_cycle_before, half_loop_range, hc_before_is_pair);
                RuffleControlPoints cp_after = RuffleControlPoints::compute(pn_half_cycle_after, half_loop_range, !hc_before_is_pair);

                float3 spline_cp[4];
                if (spline_segment_within_half_cycle < 0.5) {
                    spline_cp[0] = cp_before.back;
                    spline_cp[1] = cp_before.half_cycle;
                    spline_cp[2] = cp_before.forward;
                    spline_cp[3] = cp_after.back;
                } else if (spline_segment_within_half_cycle < 1.5) {
                    spline_cp[0] = cp_before.half_cycle;
                    spline_cp[1] = cp_before.forward;
                    spline_cp[2] = cp_after.back;
                    spline_cp[3] = cp_after.half_cycle;
                } else {
                    spline_cp[0] = cp_before.forward;
                    spline_cp[1] = cp_after.back;
                    spline_cp[2] = cp_after.half_cycle;
                    spline_cp[3] = cp_after.forward;
                }

                // Spline interpolation position
                float4x4 spline_coefficients = (1.0 / 6.0) * float4x4(
                    -1.0, 3.0, -3.0, 1.0, // t^3
                    3.0, -6.0, 3.0, 0.0, // t^2
                    -3.0, 0.0, 3.0, 0.0, // t
                    1.0, 4.0, 1.0, 0.0 // 1
                );
                float4 spline_b = spline_coefficients[0];
                spline_b = offset_within_spline_segment * spline_b + spline_coefficients[1];
                spline_b = offset_within_spline_segment * spline_b + spline_coefficients[2];
                spline_b = offset_within_spline_segment * spline_b + spline_coefficients[3];

                synthesized_input.position_os = (
                    spline_b[0] * spline_cp[0] +
                    spline_b[1] * spline_cp[1] +
                    spline_b[2] * spline_cp[2] +
                    spline_b[3] * spline_cp[3]
                );

                // Spline derivative = tangent along spline
                float3x4 spline_derivative_coefficients = float3x4(
                    spline_coefficients[0] * 3, // t^2
                    spline_coefficients[1] * 2, // t
                    spline_coefficients[2] // 1
                );
                float4 spline_derivative_b = spline_derivative_coefficients[0];
                spline_derivative_b = offset_within_spline_segment * spline_derivative_b + spline_derivative_coefficients[1];
                spline_derivative_b = offset_within_spline_segment * spline_derivative_b + spline_derivative_coefficients[2];

                synthesized_input.tangent_os = normalize(
                    spline_derivative_b[0] * spline_cp[0] +
                    spline_derivative_b[1] * spline_cp[1] +
                    spline_derivative_b[2] * spline_cp[2] +
                    spline_derivative_b[3] * spline_cp[3]
                );

                // TODO curve along y.
                // TODO binormal from dcurve_y
                // TODO normal from cross

                //synthesized_input.position_os = lerp(spline_cp[1], spline_cp[2], offset_within_spline_segment);
                //synthesized_input.position_os = lerp(cp_before.half_cycle + _Ruffle_Test * pn_half_cycle_before.tangent_u, cp_after.half_cycle + _Ruffle_Test * pn_half_cycle_after.tangent_u, offset_01_within_half_cycle);
                //synthesized_input.position_os = pn.position;
                
                synthesized_input.uv = pn.uv;

                synthesized_input.normal_os = pn.normal;
                
                vertex_stage(synthesized_input, output);
            }

            ENDCG
        }
    }
}
