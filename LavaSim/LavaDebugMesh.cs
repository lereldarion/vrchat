#if UNITY_EDITOR
using UnityEditor;
using UnityEngine;

public class LavaDebugMesh : MonoBehaviour
{
    public int PointCount;
    public float BoundingBoxRadius = 100;

    [MenuItem("Tools/LavaGenerateDebugMesh")]
    static void GenerateMesh()
    {
        Mesh mesh = new Mesh();
        mesh.vertices = new Vector3[1];
        mesh.bounds = new Bounds(Vector3.zero, Vector3.one * 10000f);
        mesh.SetIndices(new int[128], MeshTopology.Points, 0, false /*recompute bounds*/);
        AssetDatabase.CreateAsset(mesh, "Assets/Scene/LavaSim/DebugMesh.asset");
    }
}

/*[CustomEditor(typeof(LavaDebugMesh), true)]
public class LavaDebugMesh_Editor : Editor
{
    public override void OnInspectorGUI()
    {
        DrawDefaultInspector();

        if(GUILayout.Button("Generate"))
        {
            //
        }
    }
}*/
#endif