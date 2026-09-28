namespace PlantBasedPizza.OrderManager.Core.CancelOrder;

public class CancelOrderResult
{
    public bool CancelSuccess { get; set; }

    // Set when a payment was requested for the order (it was submitted), so it must be refunded.
    public bool RefundRequired { get; set; }

    public decimal RefundAmount { get; set; }
}
