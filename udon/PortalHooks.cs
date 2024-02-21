
using TMPro;
using UdonSharp;
using UnityEngine;
using VRC.SDK3.Components;
using VRC.SDKBase;
using VRC.Udon;
using VRC.Utility;

namespace Lereldarion {
// Hook system to detect portal placement and manipulate it.
// Attach to a Rigidbody kinematic trigger collider with Water-only mask (https://creators.vrchat.com/worlds/layers/)
[UdonBehaviourSyncMode(BehaviourSyncMode.None)]
public class PortalHooks : UdonSharpBehaviour {
    public TextMeshProUGUI debug_display;
    public Material debug_quad_material;

    public VRCPortalMarker static_portal_marker;

    public Transform relocation_target;
    private Collider latest_dynamic_portal_collider = null;

    public void OnTriggerEnter(Collider new_source) {
        // Ignore static portal
        if(new_source.transform.name == "PortalInternal(Clone)") {
            return;
        }

        debug_display.text = DumpObjectHierarchyRecursive(new_source.transform, 0);

        if(new_source.transform.name == "PortalInternalDynamic(Clone)") {
            DynamicPortalHooks(new_source);
        }
    }

    public void AnalyzeStaticPortal() {
        debug_display.text = DumpObjectHierarchyRecursive(static_portal_marker.transform, 0);
        debug_quad_material.mainTexture = ExtractTextureFromStaticPortal(static_portal_marker);
    }

    private void DynamicPortalHooks(Collider new_portal_collider) {
        // Relocation workd fine. Transform indicates the base of the portal, facing +Z.
        if(relocation_target != null) {
            new_portal_collider.transform.position = relocation_target.position;
            new_portal_collider.transform.rotation = relocation_target.rotation;
        }

        // NameTag and WorldTexture not available after a small delay (data loading)
        latest_dynamic_portal_collider = new_portal_collider;
        SendCustomEventDelayedSeconds("DelayedDynamicPortalHooks", 5);
    }
    public void DelayedDynamicPortalHooks() {
        if(latest_dynamic_portal_collider == null) { return; }
            
        debug_quad_material.mainTexture = ExtractTextureFromDynamicPortal(latest_dynamic_portal_collider);  

        // Cannot access roomId directly. Probably stored as a property in unaccessible components.
        // I can get room name and player source by parsing the nametag.
        string world_name = null;
        string player_name = null;
        var nametag = latest_dynamic_portal_collider.transform.Find("Canvas/NameTag");
        if(nametag != null) {
            var nametag_tmp = nametag.GetComponent<TextMeshProUGUI>();
            if(nametag_tmp != null) {
                string nametag_text = nametag_tmp.text;
                string[] lines = nametag_text.Split('\n');
                world_name = lines[0];
                player_name = lines[1]; // can be used to access VRCPlayerAPI by matching the displayName.
                debug_display.text = $"World : '{world_name}'\nUser : '{player_name}'\n";
            }
        }

        // Tried to copy settings to a static portal, but failed due to
        // - dynamic portal roomId is not exposed
        // - dynamic world name is exposed, but VRCPortalMarker.searchTerm is not.

        // Tried to clone the portal with Object.Instantiate to see what would happen.
        // The new one is not functional. Several objuscated components are missing.
        // The original portal is instantly deleted for some reason.

        latest_dynamic_portal_collider = null;
    }

    // The portal graphics using the world picture is in the "PortalCore" GameObject.
    static private Texture ExtractFromProtectedPortalCore(GameObject protected_portal_core) {
        // Sadly the renderer cannot be accessed in udon, and returns null.
        // It looks like a Udon access filter, probably selected by tag or placing specific components.
        // Clone the object with renderer ! And now we can access the renderer and its properties.
        GameObject unprotected_portal = Object.Instantiate(protected_portal_core);        
        MeshRenderer renderer = unprotected_portal.GetComponent<MeshRenderer>();
        Material material = renderer.sharedMaterial;
        // Cleanup !
        Object.DestroyImmediate(unprotected_portal);
        // World texture uses this name. 800x600 
        var texture = material.GetTexture("_WorldTex");
        return texture;
    }

    // Static portal : PortalMarker object > "PortalInternal(Clone)" with collider > PortalGraphics > PortalCore with main renderer
    static private Texture ExtractTextureFromStaticPortal(VRCPortalMarker portal_marker) {
        Transform protected_portal_core = portal_marker.transform.Find("PortalInternal(Clone)/PortalGraphics/PortalCore");
        return ExtractFromProtectedPortalCore(protected_portal_core.gameObject);
    }

    // Dynamic portal : Scene Root (unaccessible) > "PortalInternalDynamic(Clone)" with detectable collider > PortalGraphics > PortalCore with main renderer
    static private Texture ExtractTextureFromDynamicPortal(Collider portal_collider) {
        Transform protected_portal_core = portal_collider.transform.Find("PortalGraphics/PortalCore");
        return ExtractFromProtectedPortalCore(protected_portal_core.gameObject);
    }

    // Dump object hierarchy and component list
    [RecursiveMethod]
    static private string DumpObjectHierarchyRecursive(Transform node, int level) {
        // Analyze self
        bool enabled = node.gameObject.activeInHierarchy;
        string name = enabled ? node.name : $"<i>{node.name}</i>";
        string text = $"{new string('█', level)} {name} : ";
        int unreferenceable = 0;
        foreach (Component c in node.GetComponents(typeof(Component))) {
            if (c != null) {
                var type = c.GetType();
                if (type != typeof(Transform)) {
                    text += $"{type.FullName}, ";
                }
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