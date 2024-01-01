// Animated shield "energy" effect, using mostly a transparent emission disk.
// Intended usage is on a circle inscribed in a quad with UVs in [0,1]^2
// Adapted from https://www.shadertoy.com/view/tslSDX, with few modifications (move to HLSL, removal of ring, coloring)
Shader "Lereldarion/EnergyShieldSurface" {
    Properties {
        _Falloff_Radius ("Falloff radius", Range (0, 0.5)) = 0.5
		_NoiseMap ("Noise texture", 2D) = "white" {}
    }
    SubShader {
        Tags {
            "RenderType" = "Transparent"
            "Queue" = "Transparent"
            "VRCFallback" = "Hidden"
        }
        
        Cull Off
        Blend One One // Emission ; additive

        Pass {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            #include "UnityCG.cginc"
            #pragma target 5.0

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

            v2f vert (appdata i) {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.vertex = UnityObjectToClipPos(i.vertex);
                o.uv = i.uv;
                return o;
            }

            uniform float _Falloff_Radius;
            UNITY_DECLARE_TEX2D(_NoiseMap);

            float noise (float2 v){ 
                return UNITY_SAMPLE_TEX2D(_NoiseMap, v * .01).r;
            }

            float fbm (float2 p) {
                float z = 2.;
                float rz = 0.;
                UNITY_UNROLL
                for (int i = 1; i < 6; i += 1) {
                    rz += abs((noise(p) - 0.5) * 2.) / z;
                    z = z * 2.;
                    p = p * 2.;
                }
                return rz;
            }
            
            float time () {
                return _Time.y * 0.15;
            }

            float2x2 makem2 (float theta) {
                float s, c;
                sincos(theta, s, c);
                return float2x2(c, -s, s, c);
            }

            float dualfbm (float2 p) {
                // get two rotated fbm calls and displace the domain
                float2 p2 = p * .7;
                float2 basis = float2(fbm(p2 - time() * 1.6), fbm(p2 + time() * 1.7));
                basis = (basis - .5) * 0.76;
                p += basis;
            
                // coloring
                return fbm(mul(p, makem2(time() * 0.72)));
            }

            fixed4 frag (v2f i) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                
                float2 p = i.uv - 0.5; // center coordinates
                float radius = length(p);
                if (radius > _Falloff_Radius) {
                    discard;
                    // return fixed4(0, 0, 0, 0);
                }

                float3 base_color = float3(0.01, 0.12, 0.25);
                float rz = dualfbm(p * 4.); // create pattern
                float3 pattern_color = pow(abs(base_color / rz), 0.99);
                return fixed4(pattern_color, 1.);
            }
            ENDCG
        }
    }
}