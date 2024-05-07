// An overlay which amplifies lighting by using a gamma curve with fractional exponent.

Shader "Lereldarion/Overlay/GammaAdjust" {
    Properties {
        _Gamma_Adjust_Value("Gamma Adjust Value", Range(0, 1)) = 0.3
    }
    SubShader {
        Tags {
            "Queue" = "Overlay"
            "RenderType" = "Overlay"
            "VRCFallback" = "Hidden"
        }
        
        Cull Off

        GrabPass { "_GammaAdjustGrabTexture" }

        Pass {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            
            #include "UnityCG.cginc"
            #pragma target 5.0

            struct appdata {
                float4 position_os : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct v2f {
                float4 position_cs : SV_POSITION;
                float4 grab_screen_pos : GRAB_SCREEN_POS;
                float gamma : GAMMA;

                UNITY_VERTEX_OUTPUT_STEREO
            };

            float _Gamma_Adjust_Value;
            sampler2D _GammaAdjustGrabTexture;

            v2f vert (appdata i) {
                UNITY_SETUP_INSTANCE_ID(i);
                v2f o;
                o.position_cs = UnityObjectToClipPos(i.position_os);
                o.grab_screen_pos = ComputeGrabScreenPos(o.position_cs);

                o.gamma = exp(3 * (0.3 - _Gamma_Adjust_Value));

                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                fixed4 scene_color = tex2Dproj(_GammaAdjustGrabTexture, i.grab_screen_pos);
                return fixed4(pow(scene_color.rgb, i.gamma), 1);
            }

            ENDCG
        }
    }
}
