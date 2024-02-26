
using UdonSharp;
using UnityEngine;
using VRC.SDKBase;
using VRC.Udon;

// TextMeshPro text hidden by default but revealed in the field of a spotlight.
//
// Import the TMP_SDF_SpotLightReveal.shader in the project.
// In a TextMeshPro Text component, select the Font Asset (Main Settings > Font Asset ; blue F logo).
// Duplicate the Asset, relocate to one of your asset folders to avoid messing with TextMeshPro.
// On the new duplicated Font Asset click on the small arrow to show sub-assets ; select the Material.
// Change its shader to "Lereldarion/TMP_SDF_SpotLightReveal".
// The new Font Asset can then be used in any TextMeshPro Text field and configured to whatever color shceme you need.
// 
// Finally, attach the following UdonSharp component to the special reveal spotlight, and add the Material in the Font Asset to the text_mesh_pro_reveal field.
// Disabling the script, the light, or the gameobject will stop revealing text.
[UdonBehaviourSyncMode(BehaviourSyncMode.None)]
public class SpotLightConfigToRevealMat : UdonSharpBehaviour {
    [SerializeField] Material text_mesh_pro_reveal;
    private Light spot_light;

    private bool reveal_enabled = false; // cache for component.enabled && gameobject.isActive

    void Start() {
        spot_light = GetComponent<Light>();
    }

    void Update() {
        bool reveal = spot_light.enabled && reveal_enabled;
        text_mesh_pro_reveal.SetVector("_RevealLightPosition",  spot_light.transform.position);
        text_mesh_pro_reveal.SetVector("_RevealLightDirection", spot_light.transform.forward);
        text_mesh_pro_reveal.SetFloat("_RevealLightAngleCos", Mathf.Cos(spot_light.spotAngle * (3.14f/360f)));
        text_mesh_pro_reveal.SetFloat("_RevealLightRange", reveal ? spot_light.range : 0);
    }

    // These fire for either component or object status change, more reliable than individual flags
    void OnEnable() {
        reveal_enabled = true;
    }
    void OnDisable() {
        reveal_enabled = false;
        text_mesh_pro_reveal.SetFloat("_RevealLightRange", 0);
    }
}
