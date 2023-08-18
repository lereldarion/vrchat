// An overlay which displays normals of triangles in view space, from data sampled in the depth texture. Requires dynamic lighting to work (for the depth texture).
//
// Adapted from https://github.com/netri/Neitri-Unity-Shaders (by Neitri, free of charge, free to redistribute)
// Added SPS-I support
// Removed inverse matrix and moved to view space for ease of computation

Shader "Lereldarion/Overlay/ViewNormals"
{
	Properties
	{
	}
	SubShader
	{
		Tags 
		{
			"Queue" = "Overlay"
			"RenderType" = "Overlay"
			"VRCFallback" = "Hidden"
		}
		
		Cull Off

		Pass
		{
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
				float4 raw_position_cs : TEXCOORD0; // Copy but without any semantics that changes values implicitely

				UNITY_VERTEX_OUTPUT_STEREO
			};

			// Macro required: https://issuetracker.unity3d.com/issues/gearvr-singlepassstereo-image-effects-are-not-rendering-properly
			// Requires a source of dynamic light to be populated https://github.com/netri/Neitri-Unity-Shaders#types ; sad...
			UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);

			v2f vert (appdata i)
			{
				UNITY_SETUP_INSTANCE_ID(i);
				v2f o;
				o.raw_position_cs = UnityObjectToClipPos(i.position_os);
				o.position_cs = o.raw_position_cs;
				UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
				return o;
			}

			float3 scene_view_position_at(float4 position_cs, float2 screenspace_offset)
			{
				// Adjust position in screen space (due to w factor)
				position_cs.xy += screenspace_offset * position_cs.w;
				// Calculate screen UV ; here we have a legit CS position so we can use unity macros to handle the SPS-I/non SPS-I differences
				float4 screen_pos = ComputeScreenPos(position_cs);
				float2 screen_uv = screen_pos.xy / screen_pos.w;
				// Read depth, linearizing into view space z depth
				float depth_texture_value = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, screen_uv);
				float linear_depth = LinearEyeDepth(depth_texture_value);
				// Reconstruct view space of displaced pixel, but replace its w-depth by the sampled one
				float4 position_vs = mul(unity_CameraInvProjection, position_cs);
				return position_vs.xyz * linear_depth / position_cs.w;
			}

			fixed4 frag (v2f i) : SV_Target
			{
				UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

				// Idea : estimate normals in any non-projected reference frame.
				// View-space is chosen because Unity provides unity_CameraInvProjection to reconstruct view-space from screenspace uvs.
				// Normals are inferred by cross on view-space coordinates of the current pixels and its neighbors.
				
				// Pixel-neighbor offsets.
				float pixel_offset = 1.1; // Artefacts appear if we use 1.0
				float2 screenspace_uv_offset = pixel_offset / _ScreenParams.xy;

				// Sample scene position (view space) for pixels around the current one
				float3 scene_pos_0_0 = scene_view_position_at(i.raw_position_cs, float2(0, 0));
				float3 scene_pos_m_0 = scene_view_position_at(i.raw_position_cs, float2(-screenspace_uv_offset.x, 0));
				float3 scene_pos_0_p = scene_view_position_at(i.raw_position_cs, float2(0, screenspace_uv_offset.y));

				// Compute scene normals at 0 from vectors in different directions / quadrants
				float3 scene_normal_m_p = normalize(cross(scene_pos_0_p - scene_pos_0_0, scene_pos_m_0 - scene_pos_0_0));
				return float4(scene_normal_m_p, 1);
			}

			ENDCG
		}
	}
}
