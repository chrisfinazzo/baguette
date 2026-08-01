/// Minimal hand-authored USD device: a body box and a screen quad whose
/// materials carry the names the render definitions address.
enum RealityKitRenderFixtures {
    static let deviceUSDA = """
    #usda 1.0
    (
        defaultPrim = "Device"
        upAxis = "Y"
        metersPerUnit = 1
    )

    def Xform "Device"
    {
        def Mesh "Body" (
            prepend apiSchemas = ["MaterialBindingAPI"]
        )
        {
            float3[] extent = [(-1.1, -2.2, -0.1), (1.1, 2.2, 0.1)]
            int[] faceVertexCounts = [4, 4, 4, 4, 4, 4]
            int[] faceVertexIndices = [0, 1, 3, 2, 4, 6, 7, 5, 0, 4, 5, 1, 2, 3, 7, 6, 0, 2, 6, 4, 1, 5, 7, 3]
            point3f[] points = [(-1.1, -2.2, -0.1), (-1.1, -2.2, 0.1), (-1.1, 2.2, -0.1), (-1.1, 2.2, 0.1), (1.1, -2.2, -0.1), (1.1, -2.2, 0.1), (1.1, 2.2, -0.1), (1.1, 2.2, 0.1)]
            rel material:binding = </Device/Materials/DeviceBody>
        }

        def Mesh "Screen" (
            prepend apiSchemas = ["MaterialBindingAPI"]
        )
        {
            float3[] extent = [(-0.95, -1.95, 0.11), (0.95, 1.95, 0.11)]
            int[] faceVertexCounts = [4]
            int[] faceVertexIndices = [0, 1, 2, 3]
            point3f[] points = [(-0.95, -1.95, 0.11), (0.95, -1.95, 0.11), (0.95, 1.95, 0.11), (-0.95, 1.95, 0.11)]
            texCoord2f[] primvars:st = [(0, 0), (1, 0), (1, 1), (0, 1)] (
                interpolation = "vertex"
            )
            normal3f[] normals = [(0, 0, 1), (0, 0, 1), (0, 0, 1), (0, 0, 1)] (
                interpolation = "vertex"
            )
            rel material:binding = </Device/Materials/ScreenMaterial>
        }

        def Scope "Materials"
        {
            def Material "DeviceBody"
            {
                token outputs:surface.connect = </Device/Materials/DeviceBody/Shader.outputs:surface>

                def Shader "Shader"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (0.02, 0.02, 0.02)
                    float inputs:roughness = 0.9
                    token outputs:surface
                }
            }

            def Material "ScreenMaterial"
            {
                token outputs:surface.connect = </Device/Materials/ScreenMaterial/Shader.outputs:surface>

                def Shader "Shader"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (0, 0, 0)
                    float inputs:roughness = 1
                    token outputs:surface
                }
            }
        }
    }
    """
}
