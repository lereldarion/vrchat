// A simple overlay that tints color on each eyes like old school 3D glasses.
Shader "Lereldarion/Overlay/Stereo"
{
    Properties
    {
    }
    SubShader
    {
        Tags {
			"RenderType" = "Transparent"
			"Queue" = "Transparent"
			"VRCFallback" = "Hidden"
		}
		
        Cull Off // Beware of z-fighting ; does not matter now as shader is idempotent.
		Blend DstColor Zero // multiplicative

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
			#pragma multi_compile_instancing
            #include "UnityCG.cginc"
            #pragma target 5.0

            struct appdata
            {
                float4 vertex : POSITION;
				UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
				UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f vert (appdata v)
            {
                v2f o;
				UNITY_SETUP_INSTANCE_ID(v);
				UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.vertex = UnityObjectToClipPos(v.vertex);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
				UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                return lerp(
					fixed4(1, 0, 0, 1), // Left color
					fixed4(0, 0, 1, 1), // Right color
					unity_StereoEyeIndex
				);
            }
            ENDCG
        }
    }
}