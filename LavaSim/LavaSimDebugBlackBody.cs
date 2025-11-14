#if UNITY_EDITOR
using System;
using Unity.Mathematics;
using UnityEditor;
using UnityEngine;

public class LavaSimDebugBlackBody : MonoBehaviour
{
    public Texture2D BlackBody;

    [Range(1600 - 1024, 1600 - 1)]
    public float Temperature;
}

[CustomEditor(typeof(LavaSimDebugBlackBody), true)]
public class LavaSimDebugBlackBody_Editor : Editor
{
    public override void OnInspectorGUI()
    {
        DrawDefaultInspector();

        var blackbody = (LavaSimDebugBlackBody) target;
        if(blackbody.BlackBody)
        {
            var array = blackbody.BlackBody.GetRawTextureData<float>();
            var x = (int) blackbody.Temperature - (1600 - 1024);

            var emission_raw = new Vector3(array[2 * x + 0], array[2 * x + 1]);
            var emission = blackbody.BlackBody.GetPixel(x, 0);

            GUILayout.Label($"{x}: {emission_raw} ; {emission}");
        }
    }
}
#endif