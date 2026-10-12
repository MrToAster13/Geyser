/*
 * Copyright (c) 2019-2022 GeyserMC. http://geysermc.org
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 * @author GeyserMC
 * @link https://github.com/GeyserMC/Geyser
 */

package org.geysermc.geyser.translator.protocol.java.entity;

import org.geysermc.geyser.entity.type.Entity;
import org.geysermc.geyser.session.GeyserSession;
import org.geysermc.geyser.translator.protocol.PacketTranslator;
import org.geysermc.geyser.translator.protocol.Translator;
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.entity.ClientboundMoveEntityPosRotPacket;

@Translator(packet = ClientboundMoveEntityPosRotPacket.class)
public class JavaMoveEntityPosRotTranslator extends PacketTranslator<ClientboundMoveEntityPosRotPacket> {

    @Override
    public void translate(GeyserSession session, ClientboundMoveEntityPosRotPacket packet) {
        Entity entity = session.getEntityCache().getEntityByJavaId(packet.getEntityId());
        if (entity == null) return;

        // Each step is a delta from the position the previous step ended at, so the packet moves the
        // entity by the sum of all its steps. Using only the last step would lose the others for good,
        // as later deltas are added on top of them. The rotation is sent once, for the end position.
        double moveX = packet.getMoveX();
        double moveY = packet.getMoveY();
        double moveZ = packet.getMoveZ();
        if (packet.getSteps() != null) {
            for (ClientboundMoveEntityPosRotPacket.DeltaStep step : packet.getSteps()) {
                moveX += step.moveX();
                moveY += step.moveY();
                moveZ += step.moveZ();
            }
        }

        entity.updatePositionAndRotation(moveX, moveY, moveZ, packet.getYaw(), packet.getPitch(), packet.isOnGround());
    }
}
