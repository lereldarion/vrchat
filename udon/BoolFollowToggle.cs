
using UdonSharp;
using UnityEngine.UI;
using VRC.SDKBase;
using VRC.Udon;

// Attach to a UI Toggle, an make bool variable
[UdonBehaviourSyncMode(BehaviourSyncMode.None)]
public class BoolFollowToggle : UdonSharpBehaviour {
    public UdonBehaviour update_target;
    private Toggle self_toggle;

    void Start() {
        self_toggle = GetComponent<Toggle>();
        OnToggleValueChanged(); // Force sync
    }

    // Link toggle OnValueChanged to this CustomEvent
    public void OnToggleValueChanged() {
        update_target.SetProgramVariable<bool>(name, self_toggle.isOn);
    }
}
