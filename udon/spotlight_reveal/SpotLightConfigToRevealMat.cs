
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
// Disabling the script or the light will stop revealing text.
// Disabling the gameobject stops updating anything (like if light is stuck in the current state).
[UdonBehaviourSyncMode(BehaviourSyncMode.None)]
public class SpotLightConfigToRevealMat : UdonSharpBehaviour {
    [SerializeField] Material text_mesh_pro_reveal;
    private Light spot_light;

    void Start() {
        spot_light = GetComponent<Light>();
    }

    void Update() {
        bool light_on = spot_light.enabled && enabled;
        text_mesh_pro_reveal.SetVector("_MyLightPosition",  spot_light.transform.position);
        text_mesh_pro_reveal.SetVector("_MyLightDirection", spot_light.transform.forward);
        text_mesh_pro_reveal.SetFloat("_MyLightAngleCos", Mathf.Cos(spot_light.spotAngle * (3.14f/360f)));
        text_mesh_pro_reveal.SetFloat("_MyLightRange", light_on ? spot_light.range : 0);
    }
}
