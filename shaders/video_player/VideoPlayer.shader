// Intercept and display video texture from ProTV
// https://protv.dev/api/shaders-avatars
// And meybe from others if they follow the standard
Shader "Lereldarion/VideoPlayer" {
    Properties {
        //_Margins ("Margins", Vector) = (0, 0, 0, 0)
        _DisabledIcon ("TV Disabled Icon", 2D) = "white"
    }
    SubShader {
        Tags {
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
            "VRCFallback" = "Hidden"
        }

        Cull Off

        Pass {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            #include "UnityCG.cginc"

            struct appdata {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f {
                float4 vertex : SV_POSITION;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f vert (appdata input) {
                v2f output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                output.vertex = UnityObjectToClipPos(input.vertex);
                output.uv = input.uv;
                return output;
            }

            //uniform float4 _Margins;
            static const float4 _Margins = float4(0.1, 0.08, 0.14, 0.15);
            UNITY_DECLARE_TEX2D(_DisabledIcon);

            // ProTV defs ; they use explicit Texture2D to reload size
            Texture2D _Udon_VideoTex;
            SamplerState sampler_Udon_VideoTex;
            uniform float4 _Udon_VideoTex_ST;
            uniform float4x4 _Udon_VideoData;

            bool is_video_available() {
                int w;
                int h;
                _Udon_VideoTex.GetDimensions(w, h);
                return w > 16;
            }

            fixed4 frag (v2f input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                // Fix quad overlap with blocks
                float2 uv = lerp(-_Margins.xz, 1 + _Margins.yw, input.uv);

                if (!is_video_available()) {
                    uv = saturate ((uv - 0.5) * 2 + 0.5); // Center the texture, pad with white sides
                    return UNITY_SAMPLE_TEX2D(_DisabledIcon, uv);
                }

                bool2 within_rectangle = abs(uv - 0.5) < 0.5;

                if (all(within_rectangle)) {
                    // Screen : no post processing, no handling of 3d modes, no fix of aspect ratio.
                    uv = uv * _Udon_VideoTex_ST.xy + _Udon_VideoTex_ST.zw;
                    return _Udon_VideoTex.Sample(sampler_Udon_VideoTex, uv);
                } else if (uv.x < 0 && within_rectangle.y) {
                    // Left volume bar
                    float volume = _Udon_VideoData._21;
                    int player_flags = int(_Udon_VideoData._11);
                    float muted = float(player_flags >> 1 & 1);
                    fixed4 color = lerp(fixed4(0, 1, 1, 1), fixed4(0, 0, 1, 1), muted);
                    return uv.y < volume ? color : fixed4(0, 0, 0, 1);
                } else if (uv.y < 0 && within_rectangle.x) {
                    // Progress bar on bottom
                    float progress = _Udon_VideoData._22;
                    int state = int(_Udon_VideoData._12);
                    float playing = state == 2 ? 1 : 0;
                    fixed4 color = lerp(fixed4(0, 0, 1, 1), fixed4(0, 1, 1, 1), playing);
                    return uv.x < progress ? color : fixed4(0, 0, 0, 1);
                } else {
                    return fixed4(0, 0, 0, 1);
                }
            }
            ENDCG
        }
    }
}