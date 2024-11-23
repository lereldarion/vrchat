// UNITY_SHADER_NO_UPGRADE
//
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
        _Ruffle_AlphaY ("Alpha", Range(0.1, 10)) = 0.5

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
                float3 binormal_os : BINORMAL_OS;

                float2 uv0 : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID // Setup has been called
            };

            struct FragmentData {
                float4 pos : SV_POSITION; // CS, name required by stupid TRANSFER_SHADOW macro
                float2 uv0 : TEXCOORD0;
                float3 normal : NORMAL;

                fixed3 diffuse : DIFFUSE;
                fixed3 ambient : AMBIENT;
                SHADOW_COORDS(1)

                UNITY_VERTEX_OUTPUT_STEREO
            };

            void vertex_stage(const VertexData input, out FragmentData output) {                
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                output.pos = UnityObjectToClipPos (input.position_os);
                output.normal = UnityObjectToWorldNormal(input.normal_os);
                output.uv0 = input.uv0;

                // Basic lighting
                float3 normal_ws = UnityObjectToWorldNormal(input.normal_os);
                output.diffuse = max (0, dot (normal_ws, _WorldSpaceLightPos0.xyz)) * _LightColor0.rgb;
                output.ambient = ShadeSH9 (half4 (normal_ws, 1.));
                TRANSFER_SHADOW (output);
            }

            uniform fixed4 _Color;

            fixed4 fragment_stage(FragmentData input, bool is_front : SV_IsFrontFace) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX (input);

                if (!is_front) { input.normal = -input.normal; }
                return fixed4(GammaToLinearSpace(input.normal * 0.5 + 0.5), 1);

                // Basic lighting
                fixed4 color = _Color;// * fixed4(input.uv0, 0, 1);
                return color * fixed4 (input.diffuse * SHADOW_ATTENUATION (input) + input.ambient, 1.);
            }

            ///////////////////////////////////////////////////////////////////

            struct TrueVertexData {
                float3 position_os : POSITION;
                // May be non-normalized due to skinning
                float3 normal_os : NORMAL;
                float4 tangent_os : TANGENT;

                float2 uv0 : TEXCOORD0; // Used to guide ruffles : X = direction along ruffles 01, Y = from flat to thick on a ruffle 01.
                // TODO secondary uv to configure thickness & loop count
                
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationVertexData {
                float3 position_os : POSITION_OS;
                // Normalized
                float3 normal_os : NORMAL_OS;
                float3 tangent_os : TANGENT_OS;
                float3 binormal_os : BINORMAL_OS;
                float normal_scale : VERTEX_SCALE; // Kept to scale ruffle dimensions
                
                float2 uv0 : TEXCOORD0;

                // X : ruffle extremum index from 0 to 2 * ruffle_count
                float ruffle_half_cycle : RUFFLE_HALF_CYCLE;

                //bool is_culled : CULLING_STATUS; // Early culling test (before tessellation) combines per-vertex values computed here

                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationControlPoint {
                TessellationVertexData vertex;

                // Bezier displacement vectors from this vertex
                float3 d_edge_u : D_EDGE_U;
                float3 d_edge_v : D_EDGE_V;
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
            uniform float _Ruffle_AlphaY;

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
                output.normal_scale = length(input.normal_os); // Length useful to adjust ruffle thickness with skinning+scaling
                output.normal_os = input.normal_os / output.normal_scale;
                output.tangent_os = normalize(input.tangent_os.xyz);
                output.binormal_os = normalize(cross(output.normal_os, output.tangent_os)) * input.tangent_os.w;

                output.uv0 = input.uv0;

                // [0, 2N], integer. a ruffle takes 2 indexes (up down up). Necessary to have ruffle data that matches on the edge with the neighboring quad !
                output.ruffle_half_cycle = round(2.0 * _Ruffle_Cycles * input.uv0.x);

                //output.is_culled = !surface_faces_camera (output.position_ws, output.normal_ws) || !in_frustum (UnityWorldToClipPos (output.position_ws));
            }

            uint rotation_to_align_patch_with_ruffle(const InputPatch<TessellationVertexData, 4> inputs, uint id) {
                // Rotate patch to ensure ruffle_uv and patch_uv are aligned.
                // Align ruffle_uv.y positive slope with patch_uv +Y.
                // ruffle_uv.x slope is dependent on mesh orientation, so it cannot be fixed here.
                float2 current_patch_delta_uv0_y = float2(
                    (inputs[1].uv0.y + inputs[2].uv0.y) - (inputs[0].uv0.y + inputs[3].uv0.y), // u
                    (inputs[2].uv0.y + inputs[3].uv0.y) - (inputs[0].uv0.y + inputs[1].uv0.y)  // v
                );
                // 4 rotations depending on ruffle_uv.y slope orientation
                [flatten]
                if (abs(current_patch_delta_uv0_y.y) >= abs(current_patch_delta_uv0_y.x)) {
                    if (current_patch_delta_uv0_y.y >= 0) {
                        return 0; // Slope is +Y
                    } else {
                        return 2; // Slope is -Y, rotate 180
                    }
                } else {
                    if (current_patch_delta_uv0_y.x >= 0) {
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
                
                bool swaps_axis = rotation & 1 == 1;
                TessellationVertexData input_u = inputs[id ^ (swaps_axis ? 3 : 1)];
                TessellationVertexData input_v = inputs[id ^ (swaps_axis ? 1 : 3)];

                output.d_edge_u = length(input_u.position_os - input.position_os) * sign(input_u.uv0.x - input.uv0.x) * input.tangent_os;
                output.d_edge_v = length(input_v.position_os - input.position_os) * sign(input_v.uv0.y - input.uv0.y) * input.binormal_os * unity_WorldTransformParams.w;
                return output;
            }

            void hull_patch_constant_stage (const OutputPatch<TessellationControlPoint, 4> cp, out TessellationFactors factors) {
                float half_cycle_count = abs(cp[2].vertex.ruffle_half_cycle - cp[3].vertex.ruffle_half_cycle);
                float tessellation_x = half_cycle_count * _Ruffle_Tessellation_Half_Cycle; // 0 -> 0, n -> per half cycle
                
                factors.inside[0] = factors.edge[1] = factors.edge[3] = tessellation_x;
                factors.inside[1] = factors.edge[0] = factors.edge[2] = _Ruffle_Tessellation_Y;
            }

            struct InterpolatedVertexData {
                float3 position;
                float3 tangent;
                float3 binormal;
                float3 normal;
                float normal_scale;

                float2 uv0;
                float ruffle_half_cycle;

                static InterpolatedVertexData interpolate(const OutputPatch<TessellationControlPoint, 4> cp, float2 patch_uv) {
                    float4 muv_uv = float4 (1.0 - patch_uv, patch_uv);
                    float2 umu_vmv = muv_uv.xy * muv_uv.zw;
                    float4 linear_factors = muv_uv.xzzx * muv_uv.yyww;
                    float2 edge_factors = umu_vmv * (2.0 * patch_uv - 1.0);

                    float4 dlinear_factors_dx = float4(-1, 1, 1, -1) * muv_uv.yyww;
                    float4 dlinear_factors_dy = muv_uv.xzzx * float4(-1, -1, 1, 1);

                    float2 dt2mt = (-3.0 * patch_uv + 2.0) * patch_uv; // (du2mu_du, dv2mv_dv)
                    float2 dmt2t = (3.0 * patch_uv - 4.0) * patch_uv + 1.0; // (dmu2u_du, dmv2v_dv)
                    float2 dedge_factors = (-6.0 * patch_uv + 6.0) * patch_uv - 1.0;

                    InterpolatedVertexData output;

                    float4x3 cp_positions = float4x3(cp[0].vertex.position_os, cp[1].vertex.position_os, cp[2].vertex.position_os, cp[3].vertex.position_os);
                    float4x3 cp_d_edge_u = float4x3(cp[0].d_edge_u, cp[1].d_edge_u, cp[2].d_edge_u, cp[3].d_edge_u);
                    float4x3 cp_d_edge_v = float4x3(cp[0].d_edge_v, cp[1].d_edge_v, cp[2].d_edge_v, cp[3].d_edge_v);
                    float4x3 edges = float4x3(cp_positions[3] - cp_positions[0], cp_positions[1] - cp_positions[0], cp_positions[2] - cp_positions[1], cp_positions[2] - cp_positions[3]);

                    output.position = (
                        mul(linear_factors, cp_positions) +
                        umu_vmv.x * mul(linear_factors, cp_d_edge_u) +
                        umu_vmv.y * mul(linear_factors, cp_d_edge_v) +
                        mul(muv_uv * edge_factors.yxyx, edges)
                    );

                    // Derivatives give us a proper tangent+binormal, except on the edge where they are not continuous with other patches.
                    float3 dposition_dx = (
                        mul(dlinear_factors_dx, cp_positions) +
                        mul(float4(dmt2t.x, dt2mt.x, dt2mt.x, dmt2t.x) * muv_uv.yyww, cp_d_edge_u) +
                        umu_vmv.y * mul(dlinear_factors_dx, cp_d_edge_v) +
                        mul(float4(-edge_factors.y, muv_uv.y * dedge_factors.x, edge_factors.y, muv_uv.w * dedge_factors.x), edges)
                    );
                    float3 dposition_dy = (
                        mul(dlinear_factors_dy, cp_positions) +
                        umu_vmv.x * mul(dlinear_factors_dy, cp_d_edge_u) +
                        mul(muv_uv.xzzx * float4(dmt2t.y, dmt2t.y , dt2mt.y, dt2mt.y), cp_d_edge_v) +
                        mul(float4(muv_uv.x * dedge_factors.y, -edge_factors.x, muv_uv.z * dedge_factors.y, edge_factors.x), edges)
                    );
                    float3 tangent_dir = dposition_dx * sign(cp[1].vertex.uv0.x - cp[0].vertex.uv0.x);
                    float3 binormal_dir = dposition_dy * sign(cp[3].vertex.uv0.y - cp[0].vertex.uv0.y) * unity_WorldTransformParams.w;

                    // On the edges, the tangent/binormal in line with the edge is ok. But the other is not, so use a linear interpolation.
                    float2 distance_to_edges = 0.5 - abs(patch_uv - 0.5);
                    float distance_threshold = 0.01;
                    float2 edge_approximation_lerp = distance_to_edges / distance_threshold; // 0 at edge, 1 at threshold, more inside
                    if(edge_approximation_lerp.x < 1) {
                        float3 interpolated = mul(linear_factors, float4x3(cp[0].vertex.tangent_os, cp[1].vertex.tangent_os, cp[2].vertex.tangent_os, cp[3].vertex.tangent_os));
                        tangent_dir = lerp(interpolated, tangent_dir, edge_approximation_lerp.x);
                    }
                    if(edge_approximation_lerp.y < 1) {
                        float3 interpolated = mul(linear_factors, float4x3(cp[0].vertex.binormal_os, cp[1].vertex.binormal_os, cp[2].vertex.binormal_os, cp[3].vertex.binormal_os));
                        binormal_dir = lerp(interpolated, binormal_dir, edge_approximation_lerp.y);
                    }

                    // Finalize TBN
                    output.tangent = normalize(tangent_dir);
                    output.binormal = normalize(binormal_dir);
                    output.normal = normalize(cross(output.binormal, output.tangent)); 
                    output.normal_scale = dot(linear_factors, float4(cp[0].vertex.normal_scale, cp[1].vertex.normal_scale, cp[2].vertex.normal_scale, cp[3].vertex.normal_scale));

                    // Other values
                    output.uv0 = mul(linear_factors, float4x2(cp[0].vertex.uv0, cp[1].vertex.uv0, cp[2].vertex.uv0, cp[3].vertex.uv0));
                    output.ruffle_half_cycle = dot(linear_factors, float4(cp[0].vertex.ruffle_half_cycle, cp[1].vertex.ruffle_half_cycle, cp[2].vertex.ruffle_half_cycle, cp[3].vertex.ruffle_half_cycle));

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

                float3 dhalf_cycle_dy;
                float3 dsides_dy;

                static RuffleControlPoints compute(InterpolatedVertexData pn, bool half_cycle_is_pair) {
                    RuffleControlPoints cp;

                    float half_thickness = 0.5 * _Ruffle_Thickness;
                    float half_width = 0.5 * _Ruffle_Width;
                    float lateral_thickness = sqrt(pow(_Ruffle_Thickness, 2.0) - pow(half_width, 2.0)) - half_thickness; // reduce thickness on the side cp
                    
                    float3 scaled_normal = pn.normal * (half_cycle_is_pair ? 1.0 : -1.0) * pn.normal_scale;
                    float3 tangent_u_delta = pn.tangent * pn.normal_scale * half_width;
                    float3 scaled_tangent_v = pn.binormal * pn.normal_scale;
                    
                    float inv_m_exp_m_alpha = 1.0 / (1.0 - exp(-_Ruffle_AlphaY));
                    float exp_m_alpha_y = exp(-_Ruffle_AlphaY * pn.uv0.y);
                    float y_scaling = (1.0 - exp_m_alpha_y) * inv_m_exp_m_alpha;
                    float dy_scaling_dy = _Ruffle_AlphaY * exp_m_alpha_y * inv_m_exp_m_alpha;
                    
                    cp.half_cycle = pn.position + scaled_normal * half_thickness * y_scaling;
                    cp.back = pn.position + scaled_normal * lateral_thickness * y_scaling - tangent_u_delta;
                    cp.forward = pn.position + scaled_normal * lateral_thickness * y_scaling + tangent_u_delta;

                    // dy_scaling_dy : slope of vector dpos_dy in the (tangent_v, normal) plane
                    cp.dhalf_cycle_dy = scaled_normal * half_thickness * dy_scaling_dy + scaled_tangent_v;
                    cp.dsides_dy = scaled_normal * lateral_thickness * dy_scaling_dy + scaled_tangent_v; // same for both
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
                float half_cycle = pn.ruffle_half_cycle;
                float half_cycle_before = floor(half_cycle);
                float half_cycle_after = half_cycle_before + 1.0;
                float offset_01_within_half_cycle = frac(half_cycle);
                float offset_03_within_half_cycle = 3.0 * offset_01_within_half_cycle;
                float spline_segment_within_half_cycle = floor(offset_03_within_half_cycle); // 0 1 2
                float offset_within_spline_segment = frac(offset_03_within_half_cycle);

                // Sample PN surface at neighboring half loop extremities
                float2 patch_uv_half_loop_before = patch_uv;
                float2 patch_uv_half_loop_after = patch_uv;
                float half_loop_range = cp[2].vertex.ruffle_half_cycle - cp[3].vertex.ruffle_half_cycle;
                //if(half_loop_range == 0.0) { half_loop_range = 1.0; }
                patch_uv_half_loop_before.x = (half_cycle_before - cp[3].vertex.ruffle_half_cycle) / half_loop_range;
                patch_uv_half_loop_after.x = (half_cycle_after - cp[3].vertex.ruffle_half_cycle) / half_loop_range;
                InterpolatedVertexData pn_half_cycle_before = InterpolatedVertexData::interpolate(cp, patch_uv_half_loop_before);
                InterpolatedVertexData pn_half_cycle_after = InterpolatedVertexData::interpolate(cp, patch_uv_half_loop_after);

                // Use them and tangent to create b spline control points
                bool hc_before_is_pair = frac(0.5 * half_cycle_before) < 0.25;
                RuffleControlPoints cp_before = RuffleControlPoints::compute(pn_half_cycle_before, hc_before_is_pair);
                RuffleControlPoints cp_after = RuffleControlPoints::compute(pn_half_cycle_after, !hc_before_is_pair);

                float4x3 spline_cp;
                float4x3 spline_dy_cp;
                if (spline_segment_within_half_cycle < 0.5) {
                    spline_cp = float4x3(cp_before.back, cp_before.half_cycle, cp_before.forward, cp_after.back);
                    spline_dy_cp = float4x3(cp_before.dsides_dy, cp_before.dhalf_cycle_dy, cp_before.dsides_dy, cp_after.dsides_dy);
                } else if (spline_segment_within_half_cycle < 1.5) {
                    spline_cp = float4x3(cp_before.half_cycle, cp_before.forward, cp_after.back, cp_after.half_cycle);
                    spline_dy_cp = float4x3(cp_before.dhalf_cycle_dy, cp_before.dsides_dy, cp_after.dsides_dy, cp_after.dhalf_cycle_dy);
                } else {
                    spline_cp = float4x3(cp_before.forward, cp_after.back, cp_after.half_cycle, cp_after.forward);
                    spline_dy_cp = float4x3(cp_before.dsides_dy, cp_after.dsides_dy, cp_after.dhalf_cycle_dy, cp_after.dsides_dy);
                }

                // Spline interpolation position
                float spline_t = offset_within_spline_segment;
                float4 spline_t3_t2_t_1 = float4(spline_t * spline_t * spline_t, spline_t * spline_t, spline_t, 1.0);
                float4x4 spline_position_coefficients = (1.0 / 6.0) * float4x4(
                    -1.0, 3.0, -3.0, 1.0, // t^3
                    3.0, -6.0, 3.0, 0.0, // t^2
                    -3.0, 0.0, 3.0, 0.0, // t
                    1.0, 4.0, 1.0, 0.0 // 1
                );
                float4 spline_b = mul(spline_t3_t2_t_1, spline_position_coefficients);
                synthesized_input.position_os = mul(spline_b, spline_cp);

                // Spline derivative = tangent along spline.
                // TODO tangent for +ruffle_uv.x, may need to be aligned to patch for winding
                float3x4 spline_tangent_u_coefficients = float3x4(
                    spline_position_coefficients[0] * 3, // t^2
                    spline_position_coefficients[1] * 2, // t
                    spline_position_coefficients[2] // 1
                );
                float3 tangent_ruffle_x = normalize(mul(mul(spline_t3_t2_t_1.yzw, spline_tangent_u_coefficients), spline_cp));
                synthesized_input.tangent_os = tangent_ruffle_x * sign(half_loop_range);
                
                // Binormal = tangent_v = derivative of surface along +y. Interpolate +y derivatives along the spline.
                synthesized_input.binormal_os = normalize(mul(spline_b, spline_dy_cp));

                // Normal from cross
                synthesized_input.normal_os = normalize(cross(synthesized_input.tangent_os, synthesized_input.binormal_os));

                //synthesized_input.position_os = lerp(spline_cp[1], spline_cp[2], offset_within_spline_segment);
                //synthesized_input.position_os = lerp(cp_before.half_cycle, cp_after.half_cycle, offset_01_within_half_cycle);
                //synthesized_input.position_os = pn.position;
                
                synthesized_input.uv0 = pn.uv0;
                
                vertex_stage(synthesized_input, output);
            }

            ENDCG
        }
    }
}
