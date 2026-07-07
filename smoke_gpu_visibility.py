#!/usr/bin/env python3

import imath

import IECore
import IECoreImage
import IECoreScene
import GafferScene


def _render_sample(device_pattern, handle):
    IECoreImage.ImageDisplayDriver.removeStoredImage(handle)

    renderer = GafferScene.Private.IECoreScenePreview.Renderer.create(
        "Cycles", GafferScene.Private.IECoreScenePreview.Renderer.RenderType.Batch
    )
    renderer.option("cycles:session:samples", IECore.IntData(16))
    renderer.option("cycles:shadingsystem", IECore.StringData("SVM"))
    renderer.option("cycles:device", IECore.StringData(device_pattern))

    renderer.output(
        "testOutput",
        IECoreScene.Output(
            "test",
            "ieDisplay",
            "rgba",
            {
                "driverType": "ImageDisplayDriver",
                "handle": handle,
            },
        ),
    )

    plane = renderer.object(
        "/plane",
        IECoreScene.MeshPrimitive.createPlane(
            imath.Box2f(imath.V2f(-1), imath.V2f(1)),
        ),
        renderer.attributes(
            IECore.CompoundObject(
                {
                    "render:displayColor": IECore.Color3fData(imath.Color3f(1, 0.5, 0.25)),
                    "cycles:surface": IECoreScene.ShaderNetwork(
                        shaders={
                            "output": IECoreScene.Shader(
                                "principled_bsdf", "cycles:surface", {"emission_strength": 1}
                            ),
                            "info": IECoreScene.Shader("object_info", "cycles:shader"),
                        },
                        connections=[(("info", "color"), ("output", "emission_color"))],
                        output="output",
                    ),
                }
            )
        ),
    )
    plane.transform(imath.M44f().translate(imath.V3f(0, 0, -1)))

    renderer.render()

    image = IECoreImage.ImageDisplayDriver.storedImage(handle)
    if image is None:
        raise RuntimeError(f"No image returned for {device_pattern}")

    dims = image.dataWindow.size() + imath.V2i(1)
    ix = int(0.55 * (dims.x - 1))
    iy = int(0.55 * (dims.y - 1))
    i = iy * dims.x + ix
    pixel = (image["R"][i], image["G"][i], image["B"][i], image["A"][i] if "A" in image.keys() else 0.0)

    session = renderer.command("cycles:querySession", {})
    session_device = session["device"].value if "device" in session else "<unknown>"

    return pixel, session_device


def _assert_close(label, got, expected, tol=0.05):
    if any(abs(g - e) > tol for g, e in zip(got, expected)):
        raise RuntimeError(f"{label} pixel mismatch. got={got}, expected~={expected}")


def main():
    expected = (1.0, 0.5, 0.25, 1.0)

    cpu_pixel, cpu_session = _render_sample("CPU", "smokeGPUCPU")
    metal_pixel, metal_session = _render_sample("METAL:*", "smokeGPUMETAL")

    _assert_close("CPU", cpu_pixel, expected)
    _assert_close("METAL", metal_pixel, expected)

    print("CPU session:", cpu_session, "pixel:", cpu_pixel)
    print("METAL session:", metal_session, "pixel:", metal_pixel)
    print("OK: Cycles METAL renders visible geometry/material")


if __name__ == "__main__":
    main()
