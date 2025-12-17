// Made by Lereldarion (https://github.com/lereldarion/)
// Free to redistribute under the MIT license

// Procedural card design for explorer members
// Should be placed on a quad, with UVs in [0, W]x[0, 1]. UVs should not be distorded. W in [0, 1] is the aspect ratio.
// - Foreground / background textures are by default centered and using full height.
// - Recommended texture configuration : clamp + trilinear.

Shader "Lereldarion/ExplorerCard" {
    Properties {
        _MainTex("Front Texture", 2D) = "" {}

        [Header(Parallax)]
        _BackgroundTex("Background Texture", 2D) = "" {}
        _Parallax_Depth("Background parallax depth", Range(0, 1)) = 0.1

        [Header(Card Shape)]
        _Aspect_Ratio("Maximum UV width (aspect ratio)", Range(0, 1)) = 0.716
        _Corner_Radius("Radius of corners", Range(0, 0.2)) = 0.06
        
        [Header(UI)]
        _UI_Color("Color", Color) = (1, 1, 1, 1)
        _UI_Margin_Size("Size of block margins", Range(0, 0.2)) = 0.03
        _UI_Border_Thickness("Thickness of block borders", Range(0, 0.01)) = 0.001
        _UI_Title_Height("Title box height", Range(0, 0.1)) = 0.03
        _UI_Description_Height("Description box height", Range(0, 0.5)) = 0.15
        
        [Header(Blurring effect)]
        _Blur_Mip_Bias("Blur Mip bias", Range(-16, 16)) = 2
        _Blur_Darken("Darken blurred areas", Range(0, 1)) = 0.3

        [Header(Logo)]
        [NoScaleOffset] _LogoTex("Logo", 2D) = "" {}
        _Logo_Rotation_Scale_Offset("Logo rotation, scale, offset", Vector) = (30, 0.4, 0.19, -0.06)
        _Logo_Opacity("Logo opacity", Range(0, 1)) = 0.1
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
                nointerpolation float2 logo_rotation_cos_sin : LOGO_ROTATION_COS_SIN;
                UNITY_VERTEX_OUTPUT_STEREO
            };
            
            uniform Texture2D<fixed4> _MainTex;
            uniform SamplerState sampler_MainTex;
            uniform float4 _MainTex_ST;

            uniform Texture2D<fixed3> _BackgroundTex;
            uniform SamplerState sampler_BackgroundTex;
            uniform float4 _BackgroundTex_ST;
            uniform float _Parallax_Depth;

            uniform float _Aspect_Ratio;
            uniform float _Corner_Radius;
            
            uniform fixed4 _UI_Color;
            uniform float _UI_Margin_Size;
            uniform float _UI_Border_Thickness;
            uniform float _UI_Title_Height;
            uniform float _UI_Description_Height;

            uniform float _Blur_Mip_Bias;
            uniform float _Blur_Darken;

            uniform SamplerState sampler_clamp_bilinear; // unity set sampler by keywords in name https://docs.unity3d.com/Manual/SL-SamplerStates.html
            uniform Texture2D<float3> _LogoTex;
            uniform float4 _Logo_Rotation_Scale_Offset;
            uniform float _Logo_Opacity;

            void vertex_stage(VertexData input, out FragmentInput output) {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                output.position_cs = UnityObjectToClipPos(input.position);
                output.position_ws = mul(unity_ObjectToWorld, float4(input.position, 1)).xyz;
                output.normal_ws = UnityObjectToWorldNormal(input.normal);
                output.tangent_ws.xyz = UnityObjectToWorldDir(input.tangent.xyz);
                output.tangent_ws.w = input.tangent.w * unity_WorldTransformParams.w;
                output.uv0 = input.uv0;

                sincos(_Logo_Rotation_Scale_Offset.x * UNITY_PI / 180.0, output.logo_rotation_cos_sin.y, output.logo_rotation_cos_sin.x);
                output.logo_rotation_cos_sin /= _Logo_Rotation_Scale_Offset.y;
            }

            float length_sq(float2 v) { return dot(v, v); }
            float3 safe_normalize(float3 v) { return v * rsqrt(max(0.001f, dot(v, v))); }
            float2 pow2(float2 v) { return v * v; }
            
            // Inigo Quilez https://iquilezles.org/articles/distfunctions2d/
            float sdf_chamfer_box(float2 p, float2 b, float chamfer) {
                p = abs(p) - b;
                p = p.y > p.x ? p.yx : p.xy;
                p.y += chamfer;
                const float k = 1.0 - sqrt(2.0);
                if(p.y < 0 && p.y + p.x * k < 0) { return p.x; }
                if(p.x < p.y) { return (p.x + p.y) * sqrt(0.5); }
                return length(p);
            }
            float sdf_half_chamfer_box(float2 p, float2 b, float chamfer) {
                bool2 positive = p >= 0;
                return sdf_chamfer_box(p, b, positive.x != positive.y ? chamfer : 0);
            }
            
            // SDF anti-alias blend https://blog.pkh.me/p/44-perfecting-anti-aliasing-on-signed-distance-functions.html
            float sdf_blend_with_aa(float sdf) {
                const float l2_d_sdf = length(float2(ddx_fine(sdf), ddy_fine(sdf)));
                return smoothstep(-l2_d_sdf / 2, l2_d_sdf / 2, -sdf);
            }

            // MSDF textures utils https://github.com/Chlumsky/msdfgen
            float median(float3 msd) { return max(min(msd.r, msd.g), min(max(msd.r, msd.g), msd.b)); }
            float msdf_blend(Texture2D<float3> tex, float2 uv, float pixel_range) {
                // pixel range is the one used to generate the texture
                float2 texture_size;
                tex.GetDimensions(texture_size.x, texture_size.y);
                const float2 unit_range = pixel_range / texture_size;
                const float2 screen_tex_size = rsqrt(pow2(ddx_fine(uv)) + pow2(ddy_fine(uv)));
                const float screen_px_range = max(0.5 * dot(unit_range, screen_tex_size), 1.0);

                // TODO force to 0 for uv out of bounds
                const float tex_sdf = median(tex.SampleLevel(sampler_clamp_bilinear, uv, 0)) - 0.5;

                // TODO better AA ? revisit during text rendering
                const float screen_sdf = screen_px_range * tex_sdf;
                return saturate(screen_sdf + 0.5);
            }

            fixed4 fragment_stage(FragmentInput input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                // Mesh info
                const float3 view_dir_ws = normalize(_WorldSpaceCameraPos - input.position_ws);
                const float3 bitangent_ws = safe_normalize(cross(input.tangent_ws.xyz, input.normal_ws) * input.tangent_ws.w * -1);
                const float3x3 tbn_matrix = float3x3(normalize(input.tangent_ws.xyz), bitangent_ws, input.normal_ws);
                const float3 view_dir_ts = mul(tbn_matrix, view_dir_ws);

                // UVs.
                const float2 max_uv = float2(_Aspect_Ratio, 1);
                const float2 uv = input.uv0 - 0.5 * max_uv; // [-AR/2, AR/2] x [-0.5, 0.5]
                const float2 quadrant_size = 0.5 * max_uv;
                
                bool blurred = false;
                float ui_sdf;
                float logo_opacity = 0;

                // Round corners. Inigo Quilez SDF strategy, L2 distance to inner rectangle.
                if(length_sq(max(abs(uv) - (quadrant_size - _Corner_Radius), 0)) > _Corner_Radius * _Corner_Radius) {
                     discard;
                }

                // Outer box
                const float border_box_outer = sdf_chamfer_box(uv, quadrant_size - _UI_Margin_Size + _UI_Border_Thickness, _UI_Margin_Size);
                const float border_box_inner = -sdf_chamfer_box(uv, quadrant_size - _UI_Margin_Size - _UI_Border_Thickness, _UI_Margin_Size);
                ui_sdf = max(border_box_outer, border_box_inner);

                // TODO border triangles

                if(border_box_outer > 0) {
                    blurred = true;
                } else if(border_box_inner > 0) {
                    // Description
                    const float2 description_uv = uv - float2(0, _UI_Description_Height + 2 * _UI_Margin_Size - quadrant_size.y);
                    const float2 description_size = float2(quadrant_size.x - 2 * _UI_Margin_Size, _UI_Description_Height);
                    const float description_box_outer = sdf_half_chamfer_box(description_uv, description_size + _UI_Border_Thickness, 0.5 * _UI_Margin_Size);
                    const float description_box_inner = -sdf_half_chamfer_box(description_uv, description_size - _UI_Border_Thickness, 0.5 * _UI_Margin_Size);
                    ui_sdf = min(ui_sdf, max(description_box_inner, description_box_outer));

                    if(description_box_inner > 0) {
                        // Description text
                        blurred = true;

                        // Logo
                        const float2x2 logo_rotscale = float2x2(input.logo_rotation_cos_sin.xy, input.logo_rotation_cos_sin.yx * float2(-1, 1));
                        logo_opacity = msdf_blend(_LogoTex, mul(logo_rotscale, description_uv - _Logo_Rotation_Scale_Offset.zw) + 0.5, 8);

                    } else if(description_box_outer > 0) {
                        // Title
                        const float2 title_uv = uv - float2(0, quadrant_size.y - (_UI_Title_Height + 2 * _UI_Margin_Size));
                        const float2 title_size = float2(quadrant_size.x - 2 * _UI_Margin_Size, _UI_Title_Height);
                        const float title_box_outer = sdf_half_chamfer_box(title_uv, title_size + _UI_Border_Thickness, 0.5 * _UI_Margin_Size);
                        const float title_box_inner = -sdf_half_chamfer_box(title_uv, title_size - _UI_Border_Thickness, 0.5 * _UI_Margin_Size);
                        blurred = title_box_inner > 0;
                        ui_sdf = min(ui_sdf, max(title_box_inner, title_box_outer));
                    }
                }

                // Texture sampling with parallax.
                // Make tiling and offset values work on the center
                const float2 foreground_uv = uv * _MainTex_ST.xy + 0.5 + _MainTex_ST.zw;
                const float2 background_uv = (uv + ParallaxOffset(-1, _Parallax_Depth, view_dir_ts)) * _BackgroundTex_ST.xy + 0.5 + _BackgroundTex_ST.zw; // TODO fade to mipmaps on border ?
                
                // Handle blurring with mip bias : use a blurrier mip than adequate.
                // This may fail from too close if biased mip is clamped to 0 anyway, but this seems ok for 1K / 2K textures at card scale.
                const float mip_bias = blurred ? _Blur_Mip_Bias : 0;
                const fixed4 foreground = _MainTex.SampleBias(sampler_MainTex, foreground_uv, mip_bias);
                const fixed3 background = _BackgroundTex.SampleBias(sampler_BackgroundTex, background_uv, mip_bias);
                fixed3 color = lerp(background, foreground.rgb, foreground.a);

                if(blurred) {
                    color = lerp(color, 0, _Blur_Darken);
                }

                color = lerp(color, _UI_Color.rgb, logo_opacity * _Logo_Opacity);
                
                return fixed4(lerp(color, _UI_Color.rgb, sdf_blend_with_aa(ui_sdf)), 1);
            }
            ENDCG            
        }
    }
}