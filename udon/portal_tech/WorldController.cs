using TMPro;
using UdonSharp;
using UnityEngine;
using UnityEngine.UI;
using VRC.SDK3.Components;
using VRC.SDKBase;

namespace Lereldarion.PortalTech {
    // Hook system to detect portal placement and manipulate it.
    //
    // Attach to a Rigidbody kinematic trigger collider with Water-only mask (https://creators.vrchat.com/worlds/layers/)
    //
    // It can extract metadata (portal gameobject, world texture, world name).
    // The portal can then be manipulated : modify its position, appearance.
    // Some modifications are already implemented, and can be toggled on and off from a control panel.
    //
    // Tried to copy settings to a static portal, but failed due to
    // - dynamic portal roomId is not exposed
    // - dynamic world name is exposed, but VRCPortalMarker.searchTerm is not.
    //
    // Tried to clone the portal with Object.Instantiate to see what would happen.
    // The new one is not functional. Several objuscated components are missing.
    // The original portal is instantly deleted for some reason.
    [UdonBehaviourSyncMode(BehaviourSyncMode.None)]
    public class WorldController : UdonSharpBehaviour {
        [Header("Debug UI")]
        [SerializeField] TextMeshProUGUI debug_display;
        [SerializeField] Material debug_quad_material;

        [Header("Static portal")]
        [SerializeField] VRCPortalMarker static_portal_marker; // Used by analyzer, or persistence test. Not needed for Hooks

        [Header("Mesh persistent storage")]
        [SerializeField] TextMeshProUGUI persistence_message;

        [Header("Dynamic Portal Hooks")]
        [SerializeField] GameObject reskin_template;
        [SerializeField] Transform relocation_target;
        [SerializeField] GameObject collider_ghost_template;
        private bool config_reskin = false;
        private bool config_relocate = false;
        private bool config_debug = false;
        private bool config_collider_ghost = false;

        void Start() {            
            // Wait for portal marker to setup the portal mesh reference.
            SendCustomEventDelayedSeconds(nameof(RunPersistenceMessageHook), 1f);
        }

        // Access control for dump display. PlayerJoined runs for self too.
        public override void OnPlayerJoined(VRCPlayerApi player) {
            if (player.displayName == "lereldarion") {
                debug_display.enabled = true;
            }
        }
        public override void OnPlayerLeft(VRCPlayerApi player) {
            if (player.displayName == "lereldarion") {
                debug_display.enabled = false;
            }
        }

        // Collider detects probable portal
        void OnTriggerEnter(Collider new_source) {
            // Ignore static portal
            if(new_source.transform.name == "PortalInternal(Clone)") {
                return;
            }

            // Dynamic portal : Scene Root (unaccessible) > "PortalInternalDynamic(Clone)" with detectable collider
            if(new_source.transform.name == "PortalInternalDynamic(Clone)") {
                Transform new_portal_root = new_source.transform;

                // Transform indicates the base of the portal, facing +Z.
                if(relocation_target != null && config_relocate) {
                    new_portal_root.position = relocation_target.position;
                    new_portal_root.rotation = relocation_target.rotation;
                }

                if(config_reskin) {
                    PortalController.Reskin(new_portal_root, reskin_template, config_debug);
                }

                if(config_collider_ghost) {
                    GameObject ghost = Instantiate(collider_ghost_template, new_portal_root, false);

                    BoxCollider collider = new_portal_root.GetComponent<BoxCollider>();
                    ghost.transform.localPosition = collider.center;
                    ghost.transform.localScale = collider.size;
    
                    // I initially tried to remove the collider but it does not work
                    ghost.SetActive(true);
                }

                if (config_debug) {
                    debug_display.text = Utils.DumpObjectHierarchyRecursive(new_source.transform, 0);
                }
            }
        }

        // Manual button
        public void AnalyzeStaticPortal() {
            Transform portal_container = static_portal_marker.transform;
            debug_display.text = Utils.DumpObjectHierarchyRecursive(portal_container, 0);

            Transform portal_core = portal_container.Find("PortalInternal(Clone)/PortalGraphics/PortalCore");
            Texture world_texture = Utils.GetWorldTextureFromProtectedPortalCore(portal_core.gameObject);
            debug_quad_material.mainTexture = world_texture;
            debug_display.text += $"\n{world_texture.name}\n{world_texture.width}x{world_texture.height}\n";

            // Convert text to texture
            Transform nametag = portal_container.Find("PortalInternal(Clone)/Canvas/NameTag");
            //text_render_text.text = nametag.GetComponent<TextMeshProUGUI>().text.Split('\n')[0];
            //text_render_camera.Render();
        }

        // Session local storage using the Mesh of the portal.
        // For now very basic proof of concept, just store visit counter.
        public void RunPersistenceMessageHook() {
            Transform portal_core = static_portal_marker.transform.Find("PortalInternal(Clone)/PortalGraphics/PortalCore");
            if(portal_core == null) {
                return; // ClientSim
            }
            Mesh persistent_mesh = portal_core.GetComponent<MeshFilter>().sharedMesh;

            // Unpack data
            int visit_count = 0;
            Vector2[] buffer = persistent_mesh.uv8;
            if (buffer.Length > 0) {
                visit_count = (int) buffer[0].x;
            }

            // Visit logic
            if (visit_count == 0) {
                persistence_message.text = "First time ? These are dynamic portal controls";
            } else {
                persistence_message.text = $"Seen you {visit_count} time{(visit_count > 1 ? "s" : "")} today";
            }
            visit_count += 1;

            // Pack data
            buffer = new Vector2[persistent_mesh.vertexCount]; // UV must fit the vertexCount to be successfully stored.
            buffer[0].x = visit_count;
            persistent_mesh.uv8 = buffer;
        }
    }

    class Utils {
        // The portal graphics using the world picture is in the "PortalCore" GameObject. 
        // The renderer cannot be accessed in udon, and returns null. Probably a udon access filter by tag.
        // By using a little trick we can retrieve it anyway.
        // It is an instanced material, and the texture is "_WorldTex", loaded asynchronously from the CDNs.
        // The placeholder has name "active" and is 100x100.
        // Final textures contain file url in the name (NOT world id), sizes 800x600 to 1200x900 (always 4/3 ?).
        static public Texture GetWorldTextureFromProtectedPortalCore(GameObject protected_portal_core) {
            // Clone the object with renderer ! And now we can access the renderer and its properties.
            GameObject unprotected_portal = GameObject.Instantiate(protected_portal_core);        
            MeshRenderer renderer = unprotected_portal.GetComponent<MeshRenderer>();
            Material material = renderer.sharedMaterial;
            Texture texture = material.GetTexture("_WorldTex");
            GameObject.Destroy(unprotected_portal); // Cleanup temporary clone
            return texture;
        }

        // Dump object hierarchy and component list
        [RecursiveMethod]
        static public string DumpObjectHierarchyRecursive(Transform node, int level) {
            // Analyze self
            bool enabled = node.gameObject.activeInHierarchy;
            string name = enabled ? node.name : $"<i>{node.name}</i>";
            string text = $"{new string('█', level)} {name} : ";
            int unreferenceable = 0;
            foreach (Component c in node.GetComponents(typeof(Component))) {
                if (c != null) {
                    string type_name = c.GetType().FullName;
                    if(type_name.StartsWith("UnityEngine.")) {
                        type_name = type_name.Substring(12);
                    }
                    text += $"{type_name}, ";
                } else {
                    unreferenceable += 1;
                }
            }
            if (unreferenceable > 0) {
                text += $"+{unreferenceable} nulls\n";
            } else {
                text += '\n';
            }
            // Childrens
            level += 1;
            foreach(Transform child in node) {
                text += DumpObjectHierarchyRecursive(child, level);
            }
            return text;
        }
    }
}