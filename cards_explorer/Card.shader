// Made by Lereldarion (https://github.com/lereldarion/)
// Free to redistribute under the MIT license

// Procedural card design for explorer members
// - Should be placed on a quad covering the full UV square ([0,1] x [0, 1])
// - Aspect ratio is the width/height of the card ; requires a card shape (height > width)
// - Foreground / background textures are by default centered and using full height.
// - Recommended texture configuration : clamp + trilinear.

Shader "Lereldarion/ExplorerCard" {
    Properties {
        _MainTex("Front Texture", 2D) = "" {}

        [Header(Parallax)]
        _BackgroundTex("Background Texture", 2D) = "" {}
        _Parallax_Depth("Background parallax depth", Range(0, 1)) = 0.1

        _Blur_Mip_Bias("Mip bias for blurred areas", Range(-16, 16)) = 2

        [Header(Card Shape)]
        _Aspect_Ratio("Card width/height aspect ratio", Range(0, 1)) = 0.7
        _Corner_Radius("Radius of corners", Range(0, 0.2)) = 0.06

        [Header(Layout)]
        _Box_Margin_Size("Size of block margins", Range(0, 0.2)) = 0.05
        _Box_Border_Thickness("Thickness of block borders", Range(0, 0.01)) = 0.002
        _Box_Border_Color("Block border color", Color) = (1, 1, 1, 1)
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

            uniform SamplerState sampler_clamp_trilinear; // unity set sampler by keywords in name https://docs.unity3d.com/Manual/SL-SamplerStates.html
            
            uniform Texture2D<float4> _MainTex;
            uniform float4 _MainTex_ST;

            uniform Texture2D<float4> _BackgroundTex;
            uniform float4 _BackgroundTex_ST;
            uniform float _Parallax_Depth;

            uniform float _Aspect_Ratio;
            uniform float _Corner_Radius;
            
            uniform float _Blur_Mip_Bias;

            uniform float _Box_Margin_Size;
            uniform float _Box_Border_Thickness;
            uniform fixed4 _Box_Border_Color;

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

            fixed4 fragment_stage(FragmentInput input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                // Mesh info
                const float3 view_dir_ws = normalize(_WorldSpaceCameraPos - input.position_ws);
                const float3 bitangent_ws = safe_normalize(cross(input.tangent_ws.xyz, input.normal_ws) * input.tangent_ws.w * -1);
                const float3x3 tbn_matrix = float3x3(normalize(input.tangent_ws.xyz), bitangent_ws, input.normal_ws);
                const float3 view_dir_ts = mul(tbn_matrix, view_dir_ws);

                // UVs.
                // TODO find best UV description scheme for quad layout VS texture layout, stretching, etc
                const float2 uv = (input.uv0 - 0.5) * float2(_Aspect_Ratio, 1); // [-AR/2, AR/2] x [-0.5, 0.5]
                const float2 quadrant_size = 0.5 * float2(_Aspect_Ratio, 1);
                
                bool blurred = false;
                float sdf;

                // Round corners.
                // Inigo Quilez SDF strategy, L2 distance to inner rectangle
                if(length_sq(max(abs(uv) - (quadrant_size - _Corner_Radius), 0)) > _Corner_Radius * _Corner_Radius) {
                     discard;
                }

                // Outer box
                const float border_box_outer = sdf_chamfer_box(uv, quadrant_size - _Box_Margin_Size + _Box_Border_Thickness, _Box_Margin_Size);
                const float border_box_inner = -sdf_chamfer_box(uv, quadrant_size - _Box_Margin_Size - _Box_Border_Thickness, _Box_Margin_Size);
                sdf = max(border_box_outer, border_box_inner); // And

                if(border_box_outer > 0) {
                    blurred = true;
                }

                if(border_box_inner > 0) {
                    // Inner boxes
                    // TODO
                }

                // Handle blurring with mip bias : use a blurrier mip than adequate.
                // This may fail from too close if biased mip is clamped to 0 anyway, but this seems ok for 1K / 2K textures at card scale.
                const float mip_bias = blurred ? _Blur_Mip_Bias : 0;
                
                // Texture sampling with parallax.
                // Make tiling and offset values work on the center
                const float2 foreground_uv = uv * _MainTex_ST.xy + 0.5 + _MainTex_ST.zw;
                const float2 background_uv = (uv + ParallaxOffset(-1, _Parallax_Depth, view_dir_ts)) * _BackgroundTex_ST.xy + 0.5 + _BackgroundTex_ST.zw;

                const fixed4 foreground = _MainTex.SampleBias(sampler_clamp_trilinear, foreground_uv, mip_bias);
                const fixed3 background = _BackgroundTex.SampleBias(sampler_clamp_trilinear, background_uv, mip_bias);
                const fixed3 color = lerp(background, foreground.rgb, foreground.a);
                
                // SDF anti-alias blend https://blog.pkh.me/p/44-perfecting-anti-aliasing-on-signed-distance-functions.html
                const float l2_d_sdf = length(float2(ddx_fine(sdf), ddy_fine(sdf)));
                const float sdf_blend = smoothstep(-l2_d_sdf / 2, l2_d_sdf / 2, -sdf);
                return fixed4(lerp(color, _Box_Border_Color.rgb, sdf_blend), 1);
            }
            ENDCG            
        }
    }
}