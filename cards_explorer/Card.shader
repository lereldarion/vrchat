// Made by Lereldarion (https://github.com/lereldarion/)
// Free to redistribute under the MIT license

// Procedural card design for explorer members.
// Should be placed on a quad, with UVs in [0, W]x[0, 1]. UVs should not be distorded. W in [0, 1] is the aspect ratio.
// - Foreground / background textures are by default centered and using full height.
// - Recommended texture configuration : clamp + trilinear. Foreground with alpha, background without.
//
// Many properties are baked to constants now that the design is validated. The selectors are kept but commented out.

Shader "Lereldarion/ExplorerCard" {
    Properties {
        _MainTex("Avatar (alpha cutout)", 2D) = "" {}
        _BackgroundTex("Background (no alpha)", 2D) = "" {}
        _Avatar_Parallax_Depth("Avatar parallax depth", Range(0, 1)) = 0.01
        _Background_Parallax_Depth("Background parallax depth", Range(0, 1)) = 0.1

        // [Header(Card Shape)]
        // _Aspect_Ratio("Maximum UV width (aspect ratio of card quad)", Range(0, 1)) = 0.707
        // _Corner_Radius("Radius of corners", Range(0, 0.1)) = 0.024
        
        [Header(UI)]
        _UI_Color("Color", Color) = (1, 1, 1, 1)
        // _UI_Common_Margin("Common margin size", Range(0, 0.1)) = 0.03
        // _UI_Border_Thickness("Thickness of block borders", Range(0, 0.01)) = 0.0015
        // _UI_Outer_Border_Chamfer("Outer border chamfer", Range(0, 0.1)) = 0.04
        // _UI_Title_Height("Title box height", Range(0, 0.1)) = 0.036
        // _UI_Title_Chamfer("Title box chamfer", Range(0, 0.1)) = 0.023
        // _UI_Description_Height("Description box height", Range(0, 0.5)) = 0.15
        // _UI_Description_Chamfer("Description box chamfer", Range(0, 0.1)) = 0.034
        
        // [Header(Blurring effect)]
        // _Blur_Mip_Bias("Blur Mip bias", Range(-16, 16)) = 2
        // _Blur_Darken("Darken blurred areas", Range(0, 1)) = 0.3

        [Header(Logo)]
        _Logo_Color("Color", Color) = (1, 1, 1, 0.1)
        [HideInInspector] [NoScaleOffset] _LogoTex("Logo (MSDF)", 2D) = "" {}
        // _Logo_Rotation_Scale_Offset("Logo rotation, scale, offset", Vector) = (24, 0.41, 0.19, -0.1)
        // _Logo_MSDF_Pixel_Range("Logo MSDF pixel range", Float) = 8

        [Header(Text)]
        [NoScaleOffset] _FontTex("Font (MSDF)", 2D) = "" {}
        // _Font_MSDF_Pixel_Range("Font MSDF pixel range", Float) = 2
        _Font_Test_Character("Test character", Integer) = 0
        _Font_Test_Size("Test size", Float) = 1
    }
    SubShader {
        Tags {
            "RenderType" = "Opaque"
            "Queue" = "AlphaTest"
            "PreviewType" = "Plane"
            "VRCFallback" = "Unlit"
        }

        Pass {
            Cull Back
            ZTest LEqual
            ZWrite On
            Blend Off

            CGPROGRAM
            #pragma target 5.0
            #pragma multi_compile_instancing

            #pragma vertex vertex_stage
            #pragma fragment fragment_stage

            #include "UnityCG.cginc"

            struct VertexData {
                float3 position : POSITION;
                float3 normal : NORMAL;
                float4 tangent : TANGENT;
                float2 uv0 : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct FragmentInput {
                float4 position_cs : SV_POSITION;
                float3 position_ws : POSITION_WS;
                float3 normal_ws : NORMAL_WS;
                float4 tangent_ws : TANGENT_WS;
                float2 uv0 : UV0;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            // Common hardcoded sampler. Set by keywords in name https://docs.unity3d.com/Manual/SL-SamplerStates.html
            uniform SamplerState sampler_clamp_bilinear;
            
            uniform Texture2D<fixed4> _MainTex;
            uniform SamplerState sampler_MainTex;
            uniform float4 _MainTex_ST;
            uniform Texture2D<fixed3> _BackgroundTex;
            uniform SamplerState sampler_BackgroundTex;
            uniform float4 _BackgroundTex_ST;
            uniform float _Avatar_Parallax_Depth;
            uniform float _Background_Parallax_Depth;

            static const float _Aspect_Ratio = 0.707;
            static const float _Corner_Radius = 0.024;
            
            uniform fixed4 _UI_Color;
            static const float _UI_Common_Margin = 0.03;
            static const float _UI_Border_Thickness = 0.0015;
            static const float _UI_Outer_Border_Chamfer = 0.04;
            static const float _UI_Title_Height = 0.036;
            static const float _UI_Title_Chamfer = 0.023;
            static const float _UI_Description_Height = 0.15;
            static const float _UI_Description_Chamfer = 0.034;

            static const float _Blur_Mip_Bias = 2;
            static const float _Blur_Darken = 0.3;

            uniform Texture2D<float3> _LogoTex;
            uniform fixed4 _Logo_Color;
            static const float4 _Logo_Rotation_Scale_Offset = float4(24, 0.41, 0.19, -0.1);
            static const float _Logo_MSDF_Pixel_Range = 8;

            uniform Texture2D<float3> _FontTex;
            static const float _Font_MSDF_Pixel_Range = 2;
            uniform uint _Font_Test_Character;
            uniform float _Font_Test_Size;

            void vertex_stage(VertexData input, out FragmentInput output) {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                output.position_cs = UnityObjectToClipPos(input.position);
                output.position_ws = mul(unity_ObjectToWorld, float4(input.position, 1)).xyz;
                output.normal_ws = UnityObjectToWorldNormal(input.normal);
                output.tangent_ws.xyz = UnityObjectToWorldDir(input.tangent.xyz);
                output.tangent_ws.w = input.tangent.w * unity_WorldTransformParams.w;
                output.uv0 = input.uv0;
            }

            float length_sq(float2 v) { return dot(v, v); }
            float3 safe_normalize(float3 v) { return v * rsqrt(max(0.001f, dot(v, v))); }
            float2 pow2(float2 v) { return v * v; }
            
            // Inigo Quilez https://iquilezles.org/articles/distfunctions2d/. Use negative for interior.
            float extrude_border_with_thickness(float sdf, float thickness) {
                return abs(sdf) - thickness;
            }
            float psdf_chamfer_box(float2 p, float2 b, float chamfer) {
                // Pseudo SDF, with sharp corners. Useful to keep sharp corners when thickness is added.
                const float2 d = abs(p) - b;
                const float rectangle_sd = max(d.x, d.y);
                const float chamfer_sd = sqrt(0.5) * (d.x + d.y + chamfer);
                return max(rectangle_sd, chamfer_sd);
            }
            float psdf_half_chamfer_box(float2 p, float2 b, float chamfer) {
                const float2 d = abs(p) - b;
                const float rectangle_sd = max(d.x, d.y);
                const float chamfer_sd = sqrt(0.5) * (d.x + d.y + chamfer);
                return (p.x >= 0) != (p.y >= 0) ? max(rectangle_sd, chamfer_sd) : rectangle_sd;
            }
            
            // SDF anti-alias blend https://blog.pkh.me/p/44-perfecting-anti-aliasing-on-signed-distance-functions.html
            float sdf_blend_with_aa(float sdf) {
                const float l2_d_sdf = length(float2(ddx_fine(sdf), ddy_fine(sdf)));
                return smoothstep(-l2_d_sdf / 2, l2_d_sdf / 2, -sdf);
            }

            // MSDF textures utils https://github.com/Chlumsky/msdfgen
            float median(float3 msd) { return max(min(msd.r, msd.g), min(max(msd.r, msd.g), msd.b)); }
            float msdf_blend(Texture2D<float3> tex, float2 uv, float pixel_range) {
                const float tex_sd = median(tex.SampleLevel(sampler_clamp_bilinear, uv, 0)) - 0.5;

                // Scale stored texture sdf to screen.
                // pixel_range is the one used to generate the texture
                float2 texture_size;
                tex.GetDimensions(texture_size.x, texture_size.y);
                const float2 unit_range = pixel_range / texture_size;
                const float2 screen_tex_size = rsqrt(pow2(ddx_fine(uv)) + pow2(ddy_fine(uv)));
                const float screen_px_range = max(0.5 * dot(unit_range, screen_tex_size), 1.0);
                const float screen_sd = screen_px_range * tex_sd;
                return saturate(screen_sd + 0.5);
                // TODO rework in terms of msdf_sample ?
            }
            float msdf_sample(Texture2D<float3> tex, float2 uv, float pixel_range, float2 texture_size) {
                const float tex_sd = median(tex.SampleLevel(sampler_clamp_bilinear, uv, 0)) - 0.5;

                // tex_sd is in [-0.5, 0.5]. It represents texture pixel ranges between [-pixel_range, pixel_range].
                const float texture_pixel_sd = tex_sd * 2 * pixel_range;
                const float texture_uv_sd = texture_pixel_sd / texture_size;
                return -texture_uv_sd; // MSDF tooling generates inverted SDF (positive inside)
            }

            fixed4 fragment_stage(FragmentInput input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                // Mesh info
                const float3 view_dir_ws = normalize(_WorldSpaceCameraPos - input.position_ws);
                const float3 bitangent_ws = safe_normalize(cross(input.tangent_ws.xyz, input.normal_ws) * input.tangent_ws.w * -1);
                const float3x3 tbn_matrix = float3x3(normalize(input.tangent_ws.xyz), bitangent_ws, input.normal_ws);
                const float3 view_dir_ts = mul(tbn_matrix, view_dir_ws);

                // UVs.
                const float2 raw_uv_range = float2(_Aspect_Ratio, 1);
                const float2 quadrant_size = 0.5 * raw_uv_range;
                const float2 centered_uv = input.uv0 - quadrant_size; // [-AR/2, AR/2] x [-0.5, 0.5]
                
                bool blurred = false;
                float ui_sd;
                float logo_opacity = 0;

                // Round corners. Inigo Quilez SDF strategy, L2 distance to inner rectangle.
                if(length_sq(max(abs(centered_uv) - (quadrant_size - _Corner_Radius), 0)) > _Corner_Radius * _Corner_Radius) {
                     discard;
                }

                // Outer box
                const float border_box_sd = psdf_chamfer_box(centered_uv, quadrant_size - _UI_Common_Margin, _UI_Outer_Border_Chamfer);
                ui_sd = extrude_border_with_thickness(border_box_sd, _UI_Border_Thickness);

                // Border triangles gizmos
                if((centered_uv.x >= 0) == (centered_uv.y >= 0)) {
                    const float2 p = abs(centered_uv) - (quadrant_size - _Corner_Radius); // Corner at curved edge center
                    const float rectangle_edges_sd = max(p.x, p.y);
                    const float diag_axis = sqrt(0.5) * (p.x + p.y);
                    // Align outer triangle diagonal with inner chamfer
                    const float diag_offset_a = (_UI_Common_Margin + 0.5 * _UI_Outer_Border_Chamfer - _Corner_Radius) * sqrt(2) + _UI_Border_Thickness;
                    const float diag_offset_b = diag_offset_a - 6 * _UI_Border_Thickness;
                    const float diag_offset_c = diag_offset_b - 4 * _UI_Border_Thickness;

                    const float gizmo_sd = max(rectangle_edges_sd, min(max(-(diag_axis + diag_offset_a), diag_axis + diag_offset_b), -(diag_axis + diag_offset_c)));
                    ui_sd = min(ui_sd, gizmo_sd);
                }

                if(border_box_sd > 0) {
                    blurred = true;
                } else {
                    // Description
                    const float2 description_uv = centered_uv - float2(0, _UI_Description_Height + 2 * _UI_Common_Margin - quadrant_size.y);
                    const float2 description_size = float2(quadrant_size.x - 2 * _UI_Common_Margin, _UI_Description_Height);
                    const float description_box_sd = psdf_half_chamfer_box(description_uv, description_size, _UI_Description_Chamfer);
                    ui_sd = min(ui_sd, extrude_border_with_thickness(description_box_sd, _UI_Border_Thickness));

                    if(description_box_sd <= 0) {
                        // Description text
                        blurred = true;

                        // Logo
                        float2 logo_rotation_cos_sin;
                        sincos(_Logo_Rotation_Scale_Offset.x * UNITY_PI / 180.0, logo_rotation_cos_sin.y, logo_rotation_cos_sin.x);
                        logo_rotation_cos_sin /= _Logo_Rotation_Scale_Offset.y;
                        const float2x2 logo_rotscale = float2x2(logo_rotation_cos_sin.xy, logo_rotation_cos_sin.yx * float2(-1, 1));
                        logo_opacity = msdf_blend(_LogoTex, mul(logo_rotscale, description_uv - _Logo_Rotation_Scale_Offset.zw) + 0.5, _Logo_MSDF_Pixel_Range);

                        // Text test
                        float font_tex_size = 512;
                        float2 glyph_pixels = float2(51, 46);

                        uint glyph_row = _Font_Test_Character / 10;
                        uint glyph_col = _Font_Test_Character - glyph_row * 10;

                        float font_pixel_uv = 1. / font_tex_size;
                        float2 font_glyph_uv_size = font_pixel_uv * glyph_pixels;
                        float2 cell_uv = description_uv * _Font_Test_Size + 0.5 * font_glyph_uv_size;
                        if(all(cell_uv == clamp(cell_uv, 0, font_glyph_uv_size))) {
                            float2 cell_offset = float2(font_glyph_uv_size.x * glyph_col, 1. - font_glyph_uv_size.y * (glyph_row + 1));
                            ui_sd = min(ui_sd, msdf_sample(_FontTex, cell_uv + cell_offset, _Font_MSDF_Pixel_Range, font_tex_size));
                            // artefacts due to stitching sdfs but not continuous
                        }
                    } else {
                        // Title
                        const float2 title_uv = centered_uv - float2(0, quadrant_size.y - (_UI_Title_Height + 2 * _UI_Common_Margin));
                        const float2 title_size = float2(quadrant_size.x - 2 * _UI_Common_Margin, _UI_Title_Height);
                        const float title_box_sd = psdf_half_chamfer_box(title_uv, title_size, _UI_Title_Chamfer);
                        blurred = title_box_sd <= 0;
                        ui_sd = min(ui_sd, extrude_border_with_thickness(title_box_sd, _UI_Border_Thickness));
                    }
                }

                // Texture sampling with parallax.
                // Make tiling and offset values work on the center
                const float2 avatar_uv = (centered_uv + ParallaxOffset(-1, _Avatar_Parallax_Depth, view_dir_ts)) * _MainTex_ST.xy + 0.5 + _MainTex_ST.zw;
                const float2 background_uv = (centered_uv + ParallaxOffset(-1, _Background_Parallax_Depth, view_dir_ts)) * _BackgroundTex_ST.xy + 0.5 + _BackgroundTex_ST.zw;
                
                // Handle blurring with mip bias : use a blurrier mip than adequate.
                // This may fail from too close if biased mip is clamped to 0 anyway, but this seems ok for 1K / 2K textures at card scale.
                const float mip_bias = blurred ? _Blur_Mip_Bias : 0;
                const fixed4 foreground = _MainTex.SampleBias(sampler_MainTex, avatar_uv, mip_bias);
                const fixed3 background = _BackgroundTex.SampleBias(sampler_BackgroundTex, background_uv, mip_bias);
                fixed3 color = lerp(background, foreground.rgb, foreground.a);

                if(blurred) {
                    color = lerp(color, 0, _Blur_Darken);
                }

                color = lerp(color, _Logo_Color.rgb, logo_opacity * _Logo_Color.a);
                
                return fixed4(lerp(color, _UI_Color.rgb, sdf_blend_with_aa(ui_sd)), 1);
            }
            ENDCG            
        }
    }
}