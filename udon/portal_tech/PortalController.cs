
using UdonSharp;
using UnityEngine;
using VRC.SDKBase;
using VRC.Udon;
using TMPro;
using System;

namespace Lereldarion.PortalTech {
    // Component placed on individual reskinned portals to :
    // - detect async loading of textures and use then on replacement skin
    // - follow timer and display it
    // - render world info text as texture and use it for engraving effect
    // 
    // Use : make each portal independent and parallel.
    // Expects to be installed on the portal reskin object (child of the portal root), and enabled to start operations
    [UdonBehaviourSyncMode(BehaviourSyncMode.None)]
    public class PortalController : UdonSharpBehaviour {
        [SerializeField] TextMeshProUGUI debug_display;
        [SerializeField] Material debug_quad_material;

        private MeshRenderer portal_renderer;
        private bool debug = false;

        private GameObject portal_core;
        private int remaining_world_texture_poll_attempts;
        private float world_texture_poll_delay;

        private TextMeshProUGUI timer_field;
        private float current_timer_end;

        private TextMeshProUGUI world_info;
        [SerializeField] TextRenderingSetup text_rendering_setup;
        private RenderTexture text_render = null;

        // "Constructor". We cannot create components, but we can instantiate a disabled object with components.
        static public void Reskin(Transform portal_root, GameObject template, bool debug) {
            GameObject replacement_object = Instantiate(template);
            Transform replacement = replacement_object.transform;
 
            // Make existing portal elements invisible but keep them active for async loading.
            // Reparenting them to disabled objects kills the async loading.
            // So kill most element and keep the few useful ones with microscopic size to hide them.
            var microscopic = 1e-7f * Vector3.one;
            foreach(Transform element in portal_root) {
                if (element.name == "Canvas") {
                    // Canvas provides timer, title and other stuff.
                    // Cannot kill renderers, so hide them by size
                    element.localScale = microscopic;
                } else if (element.name == "PortalGraphics") {
                    // We need PortalCore for world texture, but nothing else
                    foreach(Transform graphics in element) {
                        if (graphics.name != "PortalCore") {
                            GameObject.Destroy(graphics.gameObject);
                        }
                    }
                    element.localScale = microscopic;
                } else {
                    GameObject.Destroy(element.gameObject);
                }
            }

            replacement.SetParent(portal_root, false);

            var script = replacement_object.GetComponent<PortalController>();
            script.debug = debug;

            // Fix collider bounds to match new portal
            Bounds mesh_bound_os = replacement_object.GetComponent<MeshRenderer>().localBounds;
            BoxCollider collider = portal_root.GetComponent<BoxCollider>();
            collider.center = portal_root.InverseTransformPoint(replacement.TransformPoint(mesh_bound_os.center));
            collider.size = portal_root.InverseTransformVector(replacement.TransformVector(mesh_bound_os.size));

            replacement_object.SetActive(true); // Reenable disabled object, and will call start
        }

        void Start() {         
            portal_renderer = GetComponent<MeshRenderer>();

            // Setup polling for texture load
            portal_core = transform.parent.Find("PortalGraphics/PortalCore").gameObject;
            remaining_world_texture_poll_attempts = 30;
            world_texture_poll_delay = 0.1f;
            SendCustomEventDelayedSeconds(nameof(CheckUntilWorldTextureIsLoaded), world_texture_poll_delay);

            // Name tag used to retrieve world info text
            world_info = transform.parent.Find("Canvas/NameTag").GetComponent<TextMeshProUGUI>();

            // Setup Timer Polling
            timer_field = transform.parent.Find("Canvas/Timer").GetComponent<TextMeshProUGUI>();
            current_timer_end = 0;
            UpdateTimerEndFromField();
        }

        void OnDestroy() {
            if(text_render != null) {
                text_render.Release();
            }
        }

        public void CheckUntilWorldTextureIsLoaded() {
            Texture world_texture = Utils.GetWorldTextureFromProtectedPortalCore(portal_core);

            bool is_placeholder = world_texture.name == "active";
            if (is_placeholder && remaining_world_texture_poll_attempts > 0) {
                remaining_world_texture_poll_attempts -= 1;
                world_texture_poll_delay *= 1.5f; // Exponential backoff
                SendCustomEventDelayedSeconds(nameof(CheckUntilWorldTextureIsLoaded), world_texture_poll_delay);
                return;
            }

            // Loaded, or still placeholder but gave up

            GameObject.Destroy(portal_core); // Not needed anymore

            // Assume world info text has loaded too
            var world_info_text = world_info.text;
            var world_name = world_info_text.Split('\n')[0]; // First line is world name
            text_render = text_rendering_setup.convert_to_texture(world_name);

            var mpb = new MaterialPropertyBlock();
            portal_renderer.GetPropertyBlock(mpb);
            mpb.SetTexture("_WorldTex", world_texture); // portal surface
            mpb.SetTexture("_EngravingMask", text_render); // portal frame
            portal_renderer.SetPropertyBlock(mpb);

            if(debug) {
                debug_quad_material.mainTexture = world_texture;
                debug_display.text = Utils.DumpObjectHierarchyRecursive(transform.parent, 0);
                debug_display.text += $"\n{world_texture.name}\n{world_texture.width}x{world_texture.height}\n";
                foreach(var tmp in transform.parent.GetComponentsInChildren<TextMeshProUGUI>()) {
                    debug_display.text += $"{tmp.name}: {tmp.text}\n";
                }
            }
        }

        public void UpdateTimerEndFromField() {
            int timer_secs;
            if (int.TryParse(timer_field.text, out timer_secs)) {
                float timer_end = Time.timeSinceLevelLoad + timer_secs;
                if (timer_end > current_timer_end) {
                    current_timer_end = timer_end + 0.5f; // threshold

                    // Set shader parameter
                    var mpb = new MaterialPropertyBlock();
                    portal_renderer.GetPropertyBlock(mpb);
                    mpb.SetFloat("_TimerEnd", timer_end);
                    portal_renderer.SetPropertyBlock(mpb);
                }
            }
            SendCustomEventDelayedSeconds(nameof(UpdateTimerEndFromField), 1f);
        }
    }
}