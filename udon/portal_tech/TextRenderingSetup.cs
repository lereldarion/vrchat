
using TMPro;
using UdonSharp;
using UnityEngine;
using VRC.SDKBase;
using VRC.Udon;

namespace Lereldarion.PortalTech {
    // Manages a camera + text renderer to generate RenderTextures on demand
    [UdonBehaviourSyncMode(BehaviourSyncMode.None)]
    public class TextRenderingSetup : UdonSharpBehaviour {
        private TextMeshPro text_renderer = null;
        private Camera render_camera = null;

        void Start() {
            text_renderer = GetComponentInChildren<TextMeshPro>();
            render_camera = GetComponentInChildren<Camera>();

            // Ensure things are disabled when asleep
            render_camera.enabled = false;
            text_renderer.gameObject.SetActive(false); // disable text, renderer and all. needed as layer culling mask on main camera is not propagated to VR camera...
        }

        public RenderTexture convert_to_texture(string text) {
            text_renderer.text = text;
            text_renderer.gameObject.SetActive(true);

            //RenderTexture texture = new RenderTexture(
            //    1024, 256,
            //    0, // depth
            //    RenderTextureFormat.RHalf
            //);
            //texture.useMipMap = true;
            //texture.autoGenerateMips = true;
            //texture.wrapMode = TextureWrapMode.Clamp; // Needed for uv-detail-map scheme on portal, see shader doc.
            
            RenderTexture template = render_camera.targetTexture;
            RenderTexture texture = new RenderTexture(template);
            render_camera.targetTexture = texture;
            render_camera.Render();
            render_camera.targetTexture = template;

            text_renderer.gameObject.SetActive(false);
            return texture;        
        }
    }
}