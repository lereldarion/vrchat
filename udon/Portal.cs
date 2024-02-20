// Analyze VRC portal prefab and extract useful data : world texture and name
using System.IO;
using TMPro;
using UdonSharp;
using UnityEngine;
using VRC.SDK3.Components;
using VRC.SDKBase;
using VRC.Udon;

public class Portal : UdonSharpBehaviour {
    public Transform portal_root;
    public TextMeshProUGUI info_display;
    public Material texture_display;

    [RecursiveMethod]
    private string RecursiveAnalyze(Transform node, int level) {
        // Analyze self
        bool enabled = node.gameObject.activeInHierarchy;
        string name = enabled ? node.name : $"<i>{node.name}</i>";
        string text = $"{new string('█', level)} {name} : ";
        int unreferenceable = 0;
        foreach (Component c in node.GetComponents(typeof(Component))) {
            if (c != null) {
                var type = c.GetType();
                if (type != typeof(Transform)) {
                    text += $"{type}, ";
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
            text += RecursiveAnalyze(child, level);
        }
        return text;
    }

    public void Analyze() {
        info_display.text = RecursiveAnalyze(portal_root, 0);
    }

    private Texture extract_texture(Transform portal_maker) {
        // Path of the gameobject with portal renderer using the world image.
        // Sadly the renderer cannot be accessed in udon (protection of specific gameobject by tag or component ?).
        Transform protected_portal = portal_root.Find("PortalInternal(Clone)/PortalGraphics/PortalCore");
        // Clone the object with renderer ! And now we can access the renderer and its properties.
        GameObject unprotected_portal = Object.Instantiate(protected_portal.gameObject);        
        MeshRenderer renderer = unprotected_portal.GetComponent<MeshRenderer>();
        Material material = renderer.sharedMaterial;
        // Cleanup !
        Object.DestroyImmediate(unprotected_portal);
        // World texture uses this name. 800x600 
        var texture = material.GetTexture("_WorldTex");
        return texture;
    }

    public void ExtractPortalTexture() {
        Transform protected_portal = portal_root.Find("PortalInternal(Clone)/PortalGraphics/PortalCore");
        GameObject unprotected_portal = Object.Instantiate(protected_portal.gameObject);
        string info_text = RecursiveAnalyze(unprotected_portal.transform, 0);
        
        MeshRenderer renderer = unprotected_portal.GetComponent<MeshRenderer>();
        Material material = renderer.sharedMaterial;
        Object.DestroyImmediate(unprotected_portal);
        
        var texture_names = material.GetTexturePropertyNames();
        foreach(string name in texture_names) {
            info_text += $"\n{name}";
        }

        var texture = material.GetTexture("_WorldTex");
        info_text += $"\n\nWorld Texture size: {texture.width}×{texture.height}\n";

        info_display.text = info_text;
        texture_display.mainTexture = texture;
    }
}
