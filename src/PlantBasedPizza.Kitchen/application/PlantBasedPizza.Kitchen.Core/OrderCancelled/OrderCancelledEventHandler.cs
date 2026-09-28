using System.Diagnostics;
using PlantBasedPizza.Kitchen.Core.Entities;
using PlantBasedPizza.Shared.Guards;
using Saunter.Attributes;

namespace PlantBasedPizza.Kitchen.Core.OrderCancelled
{
    public class OrderCancelledEventHandler(IKitchenRequestRepository kitchenRequestRepository)
    {
        [Channel("order.orderCancelled.v1")]
        [PublishOperation(typeof(OrderCancelledEventV1), OperationId = nameof(OrderCancelledEventV1))]
        public async Task Handle(OrderCancelledEventV1 evt)
        {
            Guard.AgainstNull(evt, nameof(evt));

            var kitchenRequest = await kitchenRequestRepository.Retrieve(evt.OrderIdentifier);

            // Cancelled before it was confirmed, so it never reached the kitchen.
            if (kitchenRequest is null)
            {
                Activity.Current?.AddTag("order.exists", false);
                return;
            }

            if (!kitchenRequest.Cancel())
            {
                Activity.Current?.AddTag("order.cancelRejected", kitchenRequest.OrderState.ToString());
                return;
            }

            await kitchenRequestRepository.Update(kitchenRequest);
        }
    }
}
