"""Open the generated enclosure in FreeCAD with a useful initial view."""

from pathlib import Path

import FreeCAD as App
import FreeCADGui as Gui


model = Path(__file__).resolve().parents[1] / "output" / "focalpoint-rev-a.FCStd"
doc = App.openDocument(str(model))

visible = {"BottomShell", "TopPlateShell", "BottomGrommet"}
for obj in doc.Objects:
    if obj.ViewObject is not None:
        obj.ViewObject.Visibility = obj.Name in visible

Gui.activeDocument().activeView().viewAxonometric()
Gui.activeDocument().activeView().fitAll()
Gui.activeDocument().activeView().setAnimationEnabled(False)
Gui.updateGui()
Gui.activeDocument().activeView().saveImage(
    str(model.parent / "focalpoint-preview.png"), 1400, 1000, "Transparent"
)
