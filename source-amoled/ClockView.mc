/*
   Swiss Railway Clock - an analog watchface for Garmin watches

   Copyright (C) 2023 Andreas Huggel <ahuggel@gmx.net>

   Permission is hereby granted, free of charge, to any person obtaining a copy of this software
   and associated documentation files (the "Software"), to deal in the Software without 
   restriction, including without limitation the rights to use, copy, modify, merge, publish, 
   distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the 
   Software is furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in all copies or 
   substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING 
   BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND 
   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, 
   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

// Implements the Swiss Railway Clock watch face for modern watches with an AMOLED display, using layers
class ClockView extends WatchUi.WatchFace {

    enum { M_LIGHT, M_DARK } // Color modes
    enum { C_FOREGROUND, C_BACKGROUND, C_TEXT } // Indexes into the colors array

    // Things we want to access from the outside. By convention, write-access is only from within ClockView.
    static public var iconFont as FontResource?;
    static public var colorMode as Number = M_DARK; // TODO: cannot be removed easily, as visible from outside ClockView
    static public var colors as Array<Number> = new Array<Number>[3]; // Foreground, background and text colors, see setColors()

    private const TWO_PI as Float = 2 * Math.PI;

    private var _isAwake as Boolean = true; // Assume we start awake and depend on onEnterSleep() to fall asleep
    private var _accentColor as Number = 0xff0055;

    // List of watchface shapes, used as indexes. Review optimizations in calcSecondData() et al. before changing the Shape enum.
    enum Shape { S_BIGTICKMARK, S_SMALLTICKMARK, S_HOURHAND, S_MINUTEHAND, S_SECONDHAND, S_SIZE }
    // A 1 dimensional array for the coordinates, size: S_SIZE (shapes) * 4 (points) * 2 (coordinates) - that's supposed to be more efficient
    private var _coords as Array<Number> = new Array<Number>[S_SIZE * 8];
    private var _secondCircleRadius as Number = 0; // Radius of the second hand circle
    private var _secondCircleCenter as Array<Number> = new Array<Number>[2]; // Center of the second hand circle

    // Cache for all numbers required to draw the second hand. These are pre-calculated in onLayout().
    private var _secondData as Array< Array<Number> > = new Array< Array<Number> >[60];

    private var _lastDrawnMin as Number = -1; // Minute when the watch face was last completely re-drawn
    private var _doWireHands as Number = 0; // Number of seconds to show the minute and hour hands was wire hands after press
    private var _wireHandsColor as Number = 0;

    private var _screenShape as Number;
    private var _screenCenter as Array<Number>;
    private var _clockRadius as Number;

    private var _secondLayer as Layer;
    private var _backgroundDc as Dc;
    private var _hourMinuteDc as Dc;
    private var _secondDc as Dc;

    private var _indicators as Indicators;

    // Constructor. Initialize the variables for this view.
    public function initialize() {
        WatchFace.initialize();

        if (config.hasAlpha()) { _wireHandsColor = Graphics.createColor(0x80, 0x80, 0x80, 0x80); }
        var deviceSettings = System.getDeviceSettings();
        _screenShape = deviceSettings.screenShape;
        var width = deviceSettings.screenWidth;
        var height = deviceSettings.screenHeight;
        _screenCenter = [width/2, height/2] as Array<Number>;
        _clockRadius = _screenCenter[0] < _screenCenter[1] ? _screenCenter[0] : _screenCenter[1];

        // Instead of a buffered bitmap, this version uses multiple layers (since API Level 3.1.0):
        //
        // 1) A background layer with the tick marks and any indicators.
        // 2) A full screen layer for the hour and minute hands.
        // 3) A dedicated layer for the second hand.
        //
        // Using layers is elegant.
        // On the other hand, this architecture requires more memory and is only feasible on CIQ 4
        // devices, i.e., on devices with a graphics pool, and on a few older models which have
        // more memory.
        // For improved performance, we're still using a clipping region for both second hands to
        // limit the area affected when clearing the layer.
        // There's potential to reduce the memory footprint by minimizing the size of the second
        // hand layers to about a quarter of the screen size and moving them every 15 seconds.

        // Initialize layers and add them to the view
        var opts = {:locX => 0, :locY => 0, :width => width, :height => height};
        var backgroundLayer = new WatchUi.Layer(opts);
        var hourMinuteLayer = new WatchUi.Layer(opts);
        _secondLayer = new WatchUi.Layer(opts);

        addLayer(backgroundLayer);
        addLayer(hourMinuteLayer);
        addLayer(_secondLayer);
        _backgroundDc = backgroundLayer.getDc() as Dc;
        _hourMinuteDc = hourMinuteLayer.getDc() as Dc;
        _secondDc = _secondLayer.getDc() as Dc;
        _backgroundDc.setAntiAlias(true); // Graphics.Dc has :setAntiAlias since API Level 3.2.0
        _hourMinuteDc.setAntiAlias(true);
        _secondDc.setAntiAlias(true);

        _indicators = new Indicators(width, height, _screenCenter, _clockRadius);
    }

    // Load resources and configure the layout of the watchface for this device
    public function onLayout(dc as Dc) as Void {
        // Load the custom font with the symbols
        if (Graphics has :FontReference) {
            var fontRef = WatchUi.loadResource(Rez.Fonts.Icons) as FontReference;
            iconFont = fontRef.get() as FontResource;
        } else {
            iconFont = WatchUi.loadResource(Rez.Fonts.Icons) as FontResource;
        }

        // A 2 dimensional array for the geometry of the watchface shapes - because the initialisation is more intuitive that way
        var shapes = new Array< Array<Float> >[S_SIZE];

        // Geometry of the hands and tick marks of the clock, as percentages of the diameter of the
        // clock face. Each of these shapes is a polygon (trapezoid), defined by
        // - its height (length),
        // - the width at the tail of the hand or tick mark,
        // - the width at the tip of the hand or tick mark,
        // - the distance from the center of the clock to the tail side (negative for a watch hand 
        //   with a tail).
        // In addition, the second hand has a circle, which is defined separately.
        // See docs/1508_CHD151_foto_b.jpg for the original design. The numbers used here deviate from 
        // that only slightly.
        //                          height, width1, width2, radius
        shapes[S_BIGTICKMARK]   = [  12.0,    3.5,    3.5,   36.5];	
        shapes[S_SMALLTICKMARK] = [   3.5,    1.4,    1.4,   45.0];
        shapes[S_HOURHAND]      = [  44.0,    6.3,    5.1,  -12.0];
        shapes[S_MINUTEHAND]    = [  57.8,    5.2,    3.7,  -12.0];
        shapes[S_SECONDHAND]    = [  47.9,    1.4,    1.4,  -16.5];

        // Convert the clock geometry data to pixels
        for (var s = 0; s < S_SIZE; s++) {
            for (var i = 0; i < 4; i++) {
                shapes[s][i] = Math.round(shapes[s][i] * _clockRadius / 50.0);
            }
        }

        // Update any indicator positions, which depend on the watchface shapes
        _indicators.updatePos(dc.getWidth(), dc.getHeight(), shapes[S_BIGTICKMARK][0], shapes[S_BIGTICKMARK][3]);

        // Map out the coordinates of all the shapes. Doing that only once reduces processing time.
        for (var s = 0; s < S_SIZE; s++) {
            var idx = s * 8;
            _coords[idx]   = -(shapes[s][1] / 2 + 0.5).toNumber();
            _coords[idx+1] = -(shapes[s][3] + 0.5).toNumber();
            _coords[idx+2] = -(shapes[s][2] / 2 + 0.5).toNumber();
            _coords[idx+3] = -(shapes[s][3] + shapes[s][0] + 0.5).toNumber();
            _coords[idx+4] =  (shapes[s][2] / 2 + 0.5).toNumber();
            _coords[idx+5] = -(shapes[s][3] + shapes[s][0] + 0.5).toNumber();
            _coords[idx+6] =  (shapes[s][1] / 2 + 0.5).toNumber();
            _coords[idx+7] = -(shapes[s][3] + 0.5).toNumber();
        }
        //System.println("("+_coords[S_SECONDHAND*8+2]+","+_coords[S_SECONDHAND*8+3]+") ("+_coords[S_SECONDHAND*8+4]+","+_coords[S_SECONDHAND*8+5]+")");
        if (_clockRadius >= 130 and 0 == (_coords[S_SECONDHAND*8+4] - _coords[S_SECONDHAND*8+2]) % 2) {
            // TODO: Check if we always get here because of the way the numbers are calculated
            _coords[S_SECONDHAND*8+6] += 1;
            _coords[S_SECONDHAND*8+4] += 1;
            //System.println("INFO: Increased the width of the second hand by 1 pixel to "+(_coords[S_SECONDHAND*8+4]-_coords[S_SECONDHAND*8+2]+1)+" pixels to make it even");
        }

        // The radius of the second hand circle in pixels, calculated from the percentage of the clock face diameter
        _secondCircleRadius = ((5.1 * _clockRadius / 50.0) + 0.5).toNumber();
        _secondCircleCenter = [ 0, _coords[S_SECONDHAND * 8 + 3]] as Array<Number>;
        // Shorten the second hand from the circle center to the edge of the circle to avoid a dark shadow
        _coords[S_SECONDHAND * 8 + 3] += _secondCircleRadius - 1;
        _coords[S_SECONDHAND * 8 + 5] += _secondCircleRadius - 1;

        // Calculate all numbers required to draw the second hand for every second
        calcSecondData();

        //var s = _secondData[0];
        //System.println("INFO: Clock radius = " + _clockRadius);
        //System.println("INFO: Secondhand circle: ("+s[0]+","+s[1]+"), r = "+_secondCircleRadius);
        //System.println("INFO: Secondhand coords: ("+s[2]+","+s[3]+") ("+s[4]+","+s[5]+") ("+s[6]+","+s[7]+") ("+s[8]+","+s[9]+")");
    }

    // Called when this View is brought to the foreground. Restore the state of this view and
    // prepare it to be shown. This includes loading resources into memory.
    public function onShow() as Void {
        // Assuming onShow() is triggered after any settings change, force the watch face
        // to be re-drawn in the next call to onUpdate(). This is to immediately react to
        // changes of the watch settings or a possible change of the DND setting.
        _lastDrawnMin = -1;
    }

    // This method is called when the device re-enters sleep mode
    public function onEnterSleep() as Void {
        _isAwake = false;
        _lastDrawnMin = -1; // Force the watchface to be re-drawn
        WatchUi.requestUpdate();
    }

    // This method is called when the device exits sleep mode
    public function onExitSleep() as Void {
        _isAwake = true;
        _lastDrawnMin = -1; // Force the watchface to be re-drawn
        WatchUi.requestUpdate();
    }

    public function startWireHands() as Void {
        _doWireHands = 6;
        _lastDrawnMin = -1;
        WatchUi.requestUpdate();
    }

    // Handle the update event. This function is called
    // 1) every second when the device is awake,
    // 2) every full minute in low-power mode, and
    // 3) it's also triggered when the device goes in or out of low-power mode
    //    (from onEnterSleep() and onExitSleep()).
    //
    // The watchface is redrawn every full minute and when the watch enters or exists sleep.
    // During sleep, the second hand is not drawn.
    public function onUpdate(dc as Dc) as Void {
        dc.clearClip(); // Still needed as the settings menu messes with the clip

        // Update the wire hands timer
        if (_doWireHands != 0) {
            _doWireHands -= 1;
            if (0 == _doWireHands) {
                _lastDrawnMin = -1;
            }
        }

        var clockTime = System.getClockTime();

        // Only re-draw the watch face if the minute changed since the last time
        if (_lastDrawnMin != clockTime.min) { 
            _lastDrawnMin = clockTime.min;

            var deviceSettings = System.getDeviceSettings();

            // Set the colors and color mode based on the relevant settings
            setColors(deviceSettings.doNotDisturb, clockTime.hour, clockTime.min);

            // Draw the background
            if (System.SCREEN_SHAPE_ROUND == _screenShape) {
                // Fill the entire background with the background color
                _backgroundDc.setColor(colors[C_BACKGROUND], colors[C_BACKGROUND]);
                _backgroundDc.clear();
            } else {
                // Fill the entire background with black and draw a circle with the background color
                _backgroundDc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
                _backgroundDc.clear();
                if (colors[C_BACKGROUND] != Graphics.COLOR_BLACK) {
                    _backgroundDc.setColor(colors[C_BACKGROUND], colors[C_BACKGROUND]);
                    _backgroundDc.fillCircle(_screenCenter[0], _screenCenter[1], _clockRadius);
                }
            }

            // Draw tick marks around the edge of the screen on the background layer
            _backgroundDc.setColor(colors[C_FOREGROUND], Graphics.COLOR_TRANSPARENT);
            for (var i = 0; i < 60; i++) {
                _backgroundDc.fillPolygon(rotateCoords(i % 5 ? S_SMALLTICKMARK : S_BIGTICKMARK, i / 60.0 * TWO_PI));
            }

            // Draw the indicators (those which are updated every minute) on the background layer
            _indicators.draw(_backgroundDc, deviceSettings, _isAwake);
            _indicators.drawHeartRate(_backgroundDc, _isAwake);

            // Clear the layer used for the hour and minute hands
            _hourMinuteDc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_TRANSPARENT);
            _hourMinuteDc.clear();

            // Draw the hour and minute hands
            var hourHandAngle = ((clockTime.hour % 12) * 60 + clockTime.min) / (12 * 60.0) * TWO_PI;
            var hourHandCoords = rotateCoords(S_HOURHAND, hourHandAngle);
            var minuteHandCoords = rotateCoords(S_MINUTEHAND, clockTime.min / 60.0 * TWO_PI);
            if (0 == _doWireHands) {
                _hourMinuteDc.setColor(colors[C_FOREGROUND], Graphics.COLOR_TRANSPARENT);
                _hourMinuteDc.fillPolygon(hourHandCoords);
                _hourMinuteDc.fillPolygon(minuteHandCoords);
            } else {
                _hourMinuteDc.setStroke(_wireHandsColor);
                _hourMinuteDc.setPenWidth(3); // TODO: Should be a percentage of the clock radius
                drawPolygon(_hourMinuteDc, hourHandCoords);
                drawPolygon(_hourMinuteDc, minuteHandCoords);
            }
        } // if (_lastDrawnMin != clockTime.min)

        _secondLayer.setVisible(_isAwake);
        if (_isAwake) {
            // Clear the clip of the second layer to delete the second hand
            _secondDc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_TRANSPARENT);
            _secondDc.clear();
            // Determine the color of the second hand and draw it
            var aci = 0;
            if (config.isEnabled(Config.I_ACCENT_CYCLE)) {
                var cnt = [0, clockTime.hour, clockTime.min, clockTime.sec][config.getValue(Config.I_ACCENT_CYCLE)];
                aci = cnt % 9;
            } else {
                aci = config.getValue(Config.I_ACCENT_COLOR);
            }
            _accentColor = [
                // Colors for the second hand
                0xff0055, // red 
                0xffaa00, // orange
                0xffff55, // yellow
                0x55ff00, // light green
                0x00aa55, // green
                0x55ffff, // light blue
                0x00AAFF, // blue
                0xaa00ff, // purple
                0xff00aa  // pink
            ][aci];
            drawSecondHand(_secondDc, clockTime.sec);
        }
    }

    // Draw the edges of a polygon
    private function drawPolygon(dc as Dc, pts as Array<Point2D>) as Void {
        var size = pts.size();
        for (var i = 0; i < size; i++) {
            var startPoint = pts[i];
            var endPoint = pts[(i + 1) % size];
            dc.drawLine(startPoint[0], startPoint[1], endPoint[0], endPoint[1]);
        }
    }

    // Draw the second hand for the given second and set the clipping region.
    // This function is performance critical (when !_isAwake) and has been optimized to use only pre-calculated numbers.
    private function drawSecondHand(dc as Dc, second as Number) as Void {
        // Use the pre-calculated numbers for the current second
        var sd = _secondData[second];
        var coords = [[sd[2], sd[3]], [sd[4], sd[5]], [sd[6], sd[7]], [sd[8], sd[9]]];

        // Set the clipping region
        dc.setClip(sd[10], sd[11], sd[12], sd[13]);

        // Draw the second hand
        dc.setColor(_accentColor, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(coords);
        dc.fillCircle(sd[0], sd[1], _secondCircleRadius);
    }

    // Calculate all numbers required to draw the second hand for every second.
    private function calcSecondData() as Void {
        for (var second = 0; second < 60; second++) {

            // Interestingly, lookup tables for the angle or sin/cos don't make this any faster.
            var angle = second * 0.104719758; // TWO_PI / 60.0
            var sin = Math.sin(angle);
            var cos = Math.cos(angle);
            var offsetX = _screenCenter[0] + 0.5;
            var offsetY = _screenCenter[1] + 0.5;

            // Rotate the center of the second hand circle
            var x = (_secondCircleCenter[0] * cos - _secondCircleCenter[1] * sin + offsetX).toNumber();
            var y = (_secondCircleCenter[0] * sin + _secondCircleCenter[1] * cos + offsetY).toNumber();

            // Rotate the rectangular portion of the second hand, using inlined code from rotateCoords() to improve performance
            // Optimized: idx = S_SECONDHAND * 8; idy = idx + 1; and etc.
            var x0 = (_coords[32] * cos - _coords[33] * sin + offsetX).toNumber();
            var y0 = (_coords[32] * sin + _coords[33] * cos + offsetY).toNumber();
            var x1 = (_coords[34] * cos - _coords[35] * sin + offsetX).toNumber();
            var y1 = (_coords[34] * sin + _coords[35] * cos + offsetY).toNumber();
            var x2 = (_coords[36] * cos - _coords[37] * sin + offsetX).toNumber();
            var y2 = (_coords[36] * sin + _coords[37] * cos + offsetY).toNumber();
            var x3 = (_coords[38] * cos - _coords[39] * sin + offsetX).toNumber();
            var y3 = (_coords[38] * sin + _coords[39] * cos + offsetY).toNumber();

            // Set the clipping region
            var xx1 = x - _secondCircleRadius;
            var yy1 = y - _secondCircleRadius;
            var xx2 = x + _secondCircleRadius;
            var yy2 = y + _secondCircleRadius;
            var minX = 65536;
            var minY = 65536;
            var maxX = 0;
            var maxY = 0;
            // coords[1], coords[2] optimized out: only consider the tail and circle coords, loop unrolled for performance,
            // use only points [x0, y0], [x3, y3], [xx1, yy1], [xx2, yy1], [xx2, yy2], [xx1, yy2], minus duplicate comparisons
            if (x0 < minX) { minX = x0; }
            if (y0 < minY) { minY = y0; }
            if (x0 > maxX) { maxX = x0; }
            if (y0 > maxY) { maxY = y0; }
            if (x3 < minX) { minX = x3; }
            if (y3 < minY) { minY = y3; }
            if (x3 > maxX) { maxX = x3; }
            if (y3 > maxY) { maxY = y3; }
            if (xx1 < minX) { minX = xx1; }
            if (yy1 < minY) { minY = yy1; }
            if (xx1 > maxX) { maxX = xx1; }
            if (yy1 > maxY) { maxY = yy1; }
            if (xx2 < minX) { minX = xx2; }
            if (yy2 < minY) { minY = yy2; }
            if (xx2 > maxX) { maxX = xx2; }
            if (yy2 > maxY) { maxY = yy2; }

            // Save the calculated numbers, add two pixels on each side of the clipping region for good measure
            //              Index: 0  1   2   3   4   5   6   7   8   9        10        11               12               13
            _secondData[second] = [x, y, x0, y0, x1, y1, x2, y2, x3, y3, minX - 2, minY - 2, maxX - minX + 4, maxY - minY + 4];
        }
    }

    // Rotate the four corner coordinates of a polygon used to draw a watch hand or a tick mark.
    // 0 degrees is at the 12 o'clock position, and increases in the clockwise direction.
    // Param shape: Index of the shape
    // Param angle: Rotation angle in radians
    // Returns the rotated coordinates of the polygon (watch hand or tick mark)
    private function rotateCoords(shape as Shape, angle as Float) as Array<Point2D> {
        var sin = Math.sin(angle);
        var cos = Math.cos(angle);
        // Optimized: Expanded the loop and avoid repeating the same operations (Thanks Inigo Tolosa for the tip!)
        var offsetX = _screenCenter[0] + 0.5;
		var offsetY = _screenCenter[1] + 0.5;
        var idx = shape * 8;
        var idy = idx + 1;
        var x0 = (_coords[idx] * cos - _coords[idy] * sin + offsetX).toNumber();
        var y0 = (_coords[idx] * sin + _coords[idy] * cos + offsetY).toNumber();
        idx = idy + 1;
        idy += 2;
        var x1 = (_coords[idx] * cos - _coords[idy] * sin + offsetX).toNumber();
        var y1 = (_coords[idx] * sin + _coords[idy] * cos + offsetY).toNumber();
        idx = idy + 1;
        idy += 2;
        var x2 = (_coords[idx] * cos - _coords[idy] * sin + offsetX).toNumber();
        var y2 = (_coords[idx] * sin + _coords[idy] * cos + offsetY).toNumber();
        idx = idy + 1;
        idy += 2;
        var x3 = (_coords[idx] * cos - _coords[idy] * sin + offsetX).toNumber();
        var y3 = (_coords[idx] * sin + _coords[idy] * cos + offsetY).toNumber();

        return [[x0, y0], [x1, y1], [x2, y2], [x3, y3]];
    }

    private function setColors(doNotDisturb as Boolean, hour as Number, min as Number) as Void {
        if (_isAwake) {
            var colorMode = M_LIGHT;
            colors = [Graphics.COLOR_WHITE, Graphics.COLOR_BLACK, Graphics.COLOR_LT_GRAY];
            var darkMode = config.getOption(Config.I_DARK_MODE);
            if (:DarkModeScheduled == darkMode) {
                var time = hour * 60 + min;
                if (time >= config.getValue(Config.I_DM_ON) or time < config.getValue(Config.I_DM_OFF)) {
                    colorMode = M_DARK;
                }
            } else if (   :On == darkMode
                       or (:DarkModeInDnD == darkMode and doNotDisturb)) {
                colorMode = M_DARK;
            }

            if (M_DARK == colorMode) {
                colors = [Graphics.COLOR_LT_GRAY, Graphics.COLOR_BLACK, Graphics.COLOR_DK_GRAY];
                // In dark mode, adjust text color based on the contrast (dimmer) setting
                var foregroundColor = config.getValue(Config.I_DM_CONTRAST);
                colors[C_FOREGROUND] = foregroundColor;
                if (Graphics.COLOR_WHITE == foregroundColor) {
                    colors[C_TEXT] = Graphics.COLOR_LT_GRAY;
                } else { // Graphics.COLOR_LT_GRAY or Graphics.COLOR_DK_GRAY
                    colors[C_TEXT] = Graphics.COLOR_DK_GRAY;
                }
            }
        } else { // !_isAwake
            colors = [Graphics.COLOR_DK_GRAY, Graphics.COLOR_BLACK, Graphics.COLOR_DK_GRAY];
        }
    }

} // class ClockView

// Receives watch face events
class ClockDelegate extends WatchUi.WatchFaceDelegate {
    private var _view as ClockView;

    // Constructor
    public function initialize(view as ClockView) {
        WatchFaceDelegate.initialize();
        _view = view;
    }

    // The onPress callback is called when user does a touch and hold (Since API Level 4.2.0)
    public function onPress(clickEvent as ClickEvent) as Boolean {
        _view.startWireHands();
        return true;
    }
}

/*
    // DEBUG
    (:typecheck(false))
    function typeName(obj) {
        if (obj instanceof Toybox.Lang.Number) {
            return "Number";
        } else if (obj instanceof Toybox.Lang.Long) {
            return "Long";
        } else if (obj instanceof Toybox.Lang.Float) {
            return "Float";
        } else if (obj instanceof Toybox.Lang.Double) {
            return "Double";
        } else if (obj instanceof Toybox.Lang.Boolean) {
            return "Boolean";
        } else if (obj instanceof Toybox.Lang.String) {
            return "String";
        } else if (obj instanceof Toybox.Lang.Array) {
            var s = "Array [";
            for (var i = 0; i < obj.size(); ++i) {
                s += typeName(obj);
                s += ", ";
            }
            s += "]";
            return s;
        } else if (obj instanceof Toybox.Lang.Dictionary) {
            var s = "Dictionary{";
            var keys = obj.keys();
            var vals = obj.values();
            for (var i = 0; i < keys.size(); ++i) {
                s += keys;
                s += ": ";
                s += vals;
                s += ", ";
            }
            s += "}";
            return s;
        } else if (obj instanceof Toybox.Time.Gregorian.Info) {
            return "Gregorian.Info";
        } else {
            return "???";
        }
    }
//*/
